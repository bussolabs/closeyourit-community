# frozen_string_literal: true

module Member
  module Monitoring
    # Server monitoring (UI Member): fleet org-level dei server con agent closeyourit-agent.
    # Lettura gated da servers.view (org-level, manage-implies-view: visible.servers);
    # gestione (rename/pause/revoke/destroy) da servers.manage. Classe flat nel modulo Monitoring
    # (MAI un modulo Member::Monitoring::Servers: ombreggerebbe ::Servers di dominio).
    class ServersController < Member::BaseController
      # CYRA-737 — la base condivisa delle pagine-elenco dell'area di controllo.
      include Indexable

      # Whitelist ordinamento (contratto Sortable#sorted). Tutte snapshot denormalizzate,
      # cheap; le decimali nullable finiscono in fondo (NULLS LAST) quando manca il dato.
      SORT_COLUMNS = {
        "host" => "LOWER(servers_hosts.name)",
        "status" => :status,
        "cpu" => :cpu_pct,
        "mem" => :mem_pct,
        "disk" => :disk_pct,
        "load" => :load_1,
        "temp" => :temp_max,
        "os" => "LOWER(servers_hosts.os_name)",
        "last_seen" => :last_seen_at
      }.freeze

      # The server page is split into tabs (the single scroll had become unusable): each tab loads
      # only what it shows, and an unknown tab falls back to the overview.
      SHOW_TABS = %w[overview metrics hardware workloads log operations alerts].freeze

      before_action :require_view
      before_action :set_host, only: %i[show edit update destroy pause resume revoke unrevoke reenroll]
      before_action :require_manage, only: %i[edit update destroy pause resume revoke unrevoke reenroll]

      # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
      remembers_filters :status, :q, :sort, only: :index

      def index
        # CYRA-456 — le soglie servono PRIMA della query: l'ordinamento di default mette in cima chi
        # sta peggio, e "peggio" si misura sulla propria soglia, non sul numero nudo (80% di disco su
        # una macchina con soglia 70 è più grave di 80% su una con soglia 90).
        @thresholds = Alerting::ServerThresholds.for(current_organization)
        # CYRA-465 — la temperatura non è esposta dai sensori su una VM: se in tutta la flotta nessun
        # campione la riporta, la colonna e la sua chiave di ordinamento sono spazio per un dato che
        # non arriverà. Il flag deriva dai dati (un bare-metal futuro la fa ricomparire da sé).
        @temp_reported = ::Servers::Sample.temperature_reported?(current_organization)
        scope = visible.servers.ordered
        scope = scope.where(status: status_filter) if status_filter.any?
        # CYRA-475 — il filtro che rende cliccabili le voci del riquadro «Da fare»: senza, il
        # riepilogo direbbe "tre macchine" e lascerebbe a chi legge il compito di trovarle.
        scope = apply_needs_filter(scope)
        # CYRA-470 — guardare un solo gruppo ("come sta la produzione"): il gruppo è un'etichetta
        # esatta, un valore fuori lista non filtra nulla e mostra "nessuna corrispondenza", mai un
        # elenco vuoto spacciato per flotta vuota.
        @group_filter = params[:group].to_s.strip.presence
        scope = scope.in_group(@group_filter) if @group_filter
        # CYRA-469 — arrivo dal conteggio «Server collegati» della pagina dei codici: mostro solo le
        # macchine registrate con QUEL codice. Il codice è caricato org-scoped, così un id d'altra
        # org non filtra nulla e non fa comparire un'etichetta falsa.
        @filtered_token = filtered_enrollment_token
        scope = scope.where(enrollment_token_id: @filtered_token.id) if @filtered_token
        scope = filter_by_search(scope, "servers_hosts.name", "servers_hosts.hostname")
        # Ordinamento di default: chi sta peggio in cima. L'alfabetico resta a un clic (sort=host),
        # e qualunque sort esplicito vince su questo.
        sort_columns = SORT_COLUMNS.merge("pressure" => pressure_sql)
        # Colonna nascosta → niente chiave di ordinamento: un ?sort=temp costruito a mano ricade
        # sull'ordine di default (Sortable ignora le chiavi fuori whitelist), non ordina un dato assente.
        sort_columns = sort_columns.except("temp") unless @temp_reported
        scope = scope.reorder(Arel.sql("#{pressure_sql} DESC NULLS LAST")) if params[:sort].blank?
        @hosts = paginated(scope, columns: sort_columns, per: ::Servers::Constants::PER_PAGE)

        hosts = visible.servers
        @up_count = scope.status_up.count
        @down_count = scope.status_down.count
        # CYRA-456 — il riepilogo diceva solo che nessuna macchina è spenta: una al limite non
        # compariva da nessuna parte. Un conteggio per metrica, sulle stesse soglie che fanno
        # scattare gli avvisi. Condizione come HASH, non stringa: il nome colonna non entra mai in una
        # stringa SQL (e chi legge — Brakeman compreso — non deve fidarsi che venga da un letterale).
        @over_threshold = OVER_THRESHOLD_METRICS.each_with_object({}) do |(needs, column), acc|
          limit = org_threshold(METRIC_FOR_COLUMN.fetch(column))
          acc[needs.to_sym] = limit ? hosts.where(column => limit..).count : 0
        end
        # CYRA-475/CYRA-470 — cosa richiede attenzione sulla flotta, dai dati già raccolti: riavvii,
        # aggiornamenti, servizi caduti E le metriche oltre soglia (disco pieno in testa). Ogni voce col
        # suo numero e col filtro che porta esattamente a quelle macchine. Solo voci con numeri veri: un
        # riquadro sempre pieno diventa rumore (è il rischio dichiarato nel ticket).
        @todo = {
          reboot: hosts.where(reboot_required: true).count,
          security_updates: hosts.where("security_updates_available > 0").count,
          services_failed: hosts.where("services_failed > 0").count
        }.merge(@over_threshold).select { |_key, count| count.positive? }
        # CYRA-470 — the fleet groups with their number of machines, for the toolbar's group filter.
        @group_counts = ::Servers::Host.group_counts_for(hosts)
        @saved_views = saved_views_for("servers")
      end

      # CYRA-924 — containers and processes sort on every column (C9), each table on its own param.
      CONTAINER_SORT_COLUMNS = {
        "name" => ->(container) { container.name.to_s.downcase },
        "health" => ->(container) { container.health },
        "cpu" => ->(container) { container.cpu_pct },
        "mem" => ->(container) { container.mem_bytes },
        "net" => ->(container) { container.net_sent_bytes.to_i + container.net_recv_bytes.to_i }
      }.freeze
      PROCESS_SORT_COLUMNS = {
        "name" => ->(process) { process["name"].to_s.downcase },
        "pid" => ->(process) { process["pid"].to_i },
        "cpu" => ->(process) { process["cpu_pct"].to_f },
        "mem" => ->(process) { process["mem_bytes"].to_i }
      }.freeze

      def show
        @tab = SHOW_TABS.include?(params[:tab]) ? params[:tab] : "overview"
        @range = range_param
        @last_sample = @host.samples.order(recorded_at: :desc).first
        # CYRA-465 — questa macchina espone i sensori di temperatura? Se non li ha mai riportati (VM
        # senza sensori) il grafico non compare e nei Dettagli si spiega perché il dato manca, invece
        # di un quarto di griglia sempre vuoto che si impara a ignorare.
        @temp_reported = @host.reports_temperature?
        # CYRA-458: le soglie effettive per i grafici + le regole di avviso che riguardano la macchina.
        @thresholds = Alerting::ServerThresholds.for(@host.organization)
        # Stream journald err/crit nella finestra di retention: the overview counts it, the log tab lists it.
        journal_scope = @host.journal_entries.where(occurred_at: ::Servers::Constants::JOURNAL_RETENTION_HOURS.hours.ago..)
        @journal_count = journal_scope.count
        send(:"load_#{@tab}_tab", journal_scope)
      end

      def edit; end

      def update
        if @host.update(host_params)
          redirect_to member_monitoring_server_path(@host), notice: t("member.servers.updated")
        else
          @errors = @host.errors.to_hash
          render :edit, status: :unprocessable_content
        end
      end

      def destroy
        # CYRA-468 — è definitiva e porta via lo storico: pretende il nome esatto della macchina, la
        # stessa conferma per digitazione delle azioni operative più in basso. Il gate vive qui, non
        # solo in pagina, così vale anche a chi salta l'interfaccia.
        return redirect_confirmation_denied unless confirmed_host_name?

        @host.destroy
        redirect_to member_monitoring_servers_path, notice: t("member.servers.deleted")
      end

      def pause  = toggle_status(:paused, :paused_notice)
      def resume = toggle_status(:pending, :resumed_notice)

      # Revoca: l'agent riceve 403 e si ferma; l'host resta visibile (marcato) e NON si ri-registra.
      # CYRA-468 — azione delicata: come destroy, senza il nome esatto non tocca niente (gate server-side).
      def revoke
        return redirect_confirmation_denied unless confirmed_host_name?

        @host.update!(revoked_at: Time.current)
        broadcast_host_state
        redirect_to member_monitoring_server_path(@host), notice: t("member.servers.revoked_notice")
      end

      def unrevoke
        @host.update!(revoked_at: nil)
        broadcast_host_state
        redirect_to member_monitoring_server_path(@host), notice: t("member.servers.unrevoked_notice")
      end

      # CYRA-245 — riadozione: la sola strada per cui la credenziale di una macchina che sta ancora
      # riportando viene sostituita. Non revoca niente qui: apre una finestra, e la vecchia credenziale
      # cade solo quando una sonda si presenta davvero — così un clic per sbaglio non lascia muta una
      # macchina viva (era esattamente il guasto: la credenziale moriva senza che nessun sostituto
      # arrivasse). Nome esatto della macchina come per «Scollega» ed «Elimina»: il gate vive qui,
      # non nella pagina.
      def reenroll
        return redirect_confirmation_denied unless confirmed_host_name?

        @host.update!(reenrollment_requested_at: Time.current, enrollment_conflict_at: nil)
        redirect_to member_monitoring_server_path(@host),
                    notice: t("member.servers.actions.reenroll_notice",
                              time: l(@host.reenrollment_expires_at, format: :short))
      end

      private

      # resume → pending: torna operativo al primo push (l'ingest lo marca up), senza fingere un up.
      def toggle_status(status, key)
        @host.update!(status: status)
        broadcast_host_state
        redirect_to member_monitoring_server_path(@host), notice: t("member.servers.#{key}")
      end

      # Le azioni di stato devono arrivare live agli ALTRI viewer (l'attore ha già il redirect) —
      # precedente identico: il triage errors broadcasta dal controller via Errors::Broadcast.
      def broadcast_host_state
        ::Servers::Broadcast.row(@host)
        ::Servers::Broadcast.stats(@host.organization_id)
        ::Servers::Broadcast.refresh(@host)
      end

      # CYRA-468 — conferma per digitazione condivisa da revoke e destroy: il nome scritto deve
      # combaciare con quello della macchina. secure_compare (non ==) come le azioni operative:
      # confronto a lunghezza costante, e su input vuoto/di lunghezza diversa torna false senza
      # sollevare (a differenza di fixed_length_secure_compare).
      def confirmed_host_name?
        ActiveSupport::SecurityUtils.secure_compare(params[:confirmation].to_s, @host.name)
      end

      def redirect_confirmation_denied
        redirect_to member_monitoring_server_path(@host), alert: t("member.servers.actions.confirmation_invalid")
      end

      # Anti-BOLA + scoping: host di un'altra org (o senza permesso) → RecordNotFound.
      def set_host
        @host = visible.servers.find(params[:id])
      end

      def host_params
        # CYRA-489/CYRA-470 — `ignored_container_patterns` e `groups` arrivano come testo (una riga o
        # una virgola per voce): la normalizzazione del model li spezza e li ripulisce. Array() perché
        # il campo è una stringa singola e il normalizzatore si aspetta una lista.
        params.permit(:name, :cpu_threshold, :mem_threshold, :disk_threshold, :ignored_container_patterns, :ignored_service_patterns, :groups)
              .tap do |permitted|
                %i[ignored_container_patterns ignored_service_patterns groups].each do |key|
                  permitted[key] = Array(permitted[key]) if permitted.key?(key)
                end
              end
      end

      def require_view
        return if can_view_servers?

        require_permission!("servers.view")
      end

      def require_manage
        require_permission!("servers.manage")
      end

      # ?range esplicito e valido → rispettalo; assente/ignoto → finestra auto coperta dai dati
      # dell'host (CYRA-457), così l'apertura non mostra 24h quasi vuota per un host giovane.
      # The overview draws a small trend next to each vital, from the same buckets as the charts.
      def load_overview_tab(journal)
        load_metrics_tab(journal)
        @containers = ::Servers::ContainerSample.latest_set_for(@host).to_a
        load_projects
      end

      def load_metrics_tab(_journal)
        @buckets = ::Servers::Sample.buckets_for([ @host.id ], @range)[@host.id] || []
      end

      # The full list of this machine's databases (searchable, sortable) lives on this tab, next to
      # the database panel: it used to be a separate tab repeating the same data.
      def load_hardware_tab(_journal)
        return unless @host.database_snapshot.is_a?(Hash) && @host.database_snapshot["databases"].present?

        rows = ::Servers::DatabaseInventory.call(hosts: [ @host ], q: search_q, sort: params[:sort], changes: true)
        @database_rows = paginated_rows(rows, per: ::Servers::Constants::DATABASES_PER_PAGE)
      end

      def load_workloads_tab(_journal)
        @containers = sorted_rows(::Servers::ContainerSample.latest_set_for(@host).to_a,
                                  columns: CONTAINER_SORT_COLUMNS, param: :containers_sort)
        @processes = sorted_rows(Array(@last_sample&.payload&.dig("processes")), columns: PROCESS_SORT_COLUMNS, param: :processes_sort)
      end

      # Cap a 100: è diagnostica recente, non un archivio.
      def load_log_tab(journal)
        @journal_entries = journal.recent.limit(100).to_a
      end

      def load_operations_tab(_journal)
        @server_actions = @host.actions.order(created_at: :desc).limit(20)
      end

      # CYRA-458 — the rules about this machine, with the last trigger here (one aggregated query).
      # CYRA-519 — rules muted ON this machine stay listed, marked: an unseen silence is a forgotten one.
      def load_alerts_tab(_journal)
        @server_rules = Alerting::Coverage.server_rules_for(@host).to_a
        @rule_last_triggered = Alerting::Coverage.last_triggered_for(@host, @server_rules.map(&:id))
        @muted_rule_ids = ::Alerting::RuleHostExclusion.where(host_id: @host.id).pluck(:rule_id).to_set
      end

      # Environment di progetto collegati: solo env dichiarati e solo progetti visibili al viewer
      # (anti-leak). CYRA-471 — i progetti riconosciuti dai dati della macchina restano una proposta.
      def load_projects
        @environment_links = @host.environment_links.declared
                                  .where(project_id: visible.projects.select(:id))
                                  .includes(:project, :environment).to_a
        @detected_projects = ::Servers::DetectedProjects.call(
          host: @host, projects: visible.projects, containers: @containers,
          linked_project_ids: @environment_links.map(&:project_id)
        )
      end

      def range_param
        return params[:range] if ::Servers::Sample::RANGES.key?(params[:range])

        ::Servers::Sample.default_range_for(@host.id)
      end

      def search_q = params[:q].to_s.strip

      # CYRA-469 — il codice di accesso su cui filtrare la flotta, o nil. Il guard sul formato uuid
      # evita che un valore arbitrario arrivi grezzo a una colonna uuid (PG::InvalidTextRepresentation);
      # il find_by org-scoped chiude il resto (un id d'altra org → nil → nessun filtro).
      UUID_FORMAT = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
      def filtered_enrollment_token
        id = params[:enrollment_token].to_s
        return unless id.match?(UUID_FORMAT)

        current_organization.server_enrollment_tokens.find_by(id: id)
      end
      # Le voci del riquadro «Da fare» come filtro dell'elenco: una sola per volta, dal link della
      # voce. Un valore inventato vale come nessun filtro, mai come lista vuota.
      NEEDS_FILTERS = {
        "reboot" => ->(scope) { scope.where(reboot_required: true) },
        "security_updates" => ->(scope) { scope.where("security_updates_available > 0") },
        "services_failed" => ->(scope) { scope.where("services_failed > 0") }
      }.freeze
      # CYRA-470 — le metriche di occupazione come filtro operativo ("disco oltre soglia" e sorelle).
      # La soglia è quella d'organizzazione, la stessa che alimenta il conteggio nel riquadro «Da
      # fare»: la voce e il filtro portano così esattamente alle stesse macchine. Senza soglia (nessuna
      # regola su quella metrica) la voce non compare e il filtro non nasconde niente.
      OVER_THRESHOLD_METRICS = { "cpu" => :cpu_pct, "mem" => :mem_pct, "disk" => :disk_pct }.freeze
      METRIC_FOR_COLUMN = { cpu_pct: :cpu, mem_pct: :mem, disk_pct: :disk }.freeze

      def apply_needs_filter(scope)
        needs = params[:needs].to_s
        if (column = OVER_THRESHOLD_METRICS[needs])
          limit = org_threshold(METRIC_FOR_COLUMN.fetch(column))
          return limit ? scope.where(column => limit..) : scope
        end
        filter = NEEDS_FILTERS[needs]
        filter ? filter.call(scope) : scope
      end

      def status_filter = enum_filter(:status, ::Servers::Host.statuses.keys)
    end
  end
end
      # La soglia d'organizzazione per una metrica: l'override per-macchina vive su ogni host e non si
      # può usare in un ORDER BY che vale per tutta la lista. È il limite dichiarato nel ticket — su
      # una macchina con soglia propria l'ordinamento la considera con quella d'org — mentre il
      # COLORE della cella, che si decide riga per riga, usa la soglia effettiva di quella macchina.
      def org_threshold(metric)
        @org_thresholds ||= @thresholds.for_host(::Servers::Host.new)
        @org_thresholds[metric]
      end

      # "Quanto sta soffrendo" una macchina: il massimo fra cpu/memoria/disco NORMALIZZATI sulla
      # propria soglia. Senza soglia per una metrica, quella metrica non partecipa — meglio non
      # ordinare su un numero che non sappiamo interpretare (è il rischio dichiarato nel ticket: la
      # soglia globale d'organizzazione può risultare fuorviante sulle macchine piccole).
      # Le colonne sono un vocabolario CHIUSO, dichiarato qui: nessun valore esterno entra
      # nell'espressione, e le soglie viaggiano come bind (sanitize_sql_array) invece che
      # interpolate. Vale anche come difesa in profondità: se un domani la soglia arrivasse da un
      # parametro, la query resterebbe comunque parametrizzata.
      PRESSURE_COLUMNS = { cpu: "servers_hosts.cpu_pct", mem: "servers_hosts.mem_pct",
                           disk: "servers_hosts.disk_pct" }.freeze

      def pressure_sql
        parts = PRESSURE_COLUMNS.filter_map do |metric, column|
          limit = org_threshold(metric).to_f
          next unless limit.positive?

          ::Servers::Host.sanitize_sql_array([ "COALESCE(#{column}, 0) / ?", limit ])
        end
        return "COALESCE(#{PRESSURE_COLUMNS.fetch(:cpu)}, 0)" if parts.empty?

        "GREATEST(#{parts.join(', ')})"
      end
