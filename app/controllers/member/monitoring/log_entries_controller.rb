# frozen_string_literal: true

module Member
  module Monitoring
    # Stream di log cross-app (UI Member). Lettura per chiunque veda i progetti
    # (scoping visible.logs, anti-BOLA). Nessun triage: i log seguono la visibilità progetti.
    # La show correla log↔errori della stessa richiesta (trace_id) e mostra i collegamenti manuali.
    class LogEntriesController < Member::BaseController
      permission_not_required "Log dei progetti visibili: sola lettura, i log seguono la visibilità del progetto " \
                              "come gli errori."

      # CYRA-737 — la base condivisa delle pagine-elenco dell'area di controllo; da lì arriva anche
      # il periodo (CYRA-340), lo stesso di errori e prestazioni, ricordato fra le pagine.
      include Indexable

      # Whitelist ordinamento (contratto Sortable#sorted). message raw (no LOWER): è la
      # tabella più grande — un funzionale LOWER() lì costerebbe troppo senza indice.
      SORT_COLUMNS = {
        "when" => :occurred_at,
        "level" => :level,
        "project" => { expr: "LOWER(projects.name)", joins: :project },
        "message" => :message,
        "logger" => :logger_name
      }.freeze

      monitoring_time_range
      # CYRA-694 — i filtri, DOPO il periodo (vedi ErrorGroupsController); `from`/`to`/`since`
      # restano il territorio del periodo, qui solo i filtri veri.
      remembers_filters :level, :environment, :release, :project_id, :q, :sort, only: :index
      before_action :set_entry, only: :show

      def index
        scope = visible.logs.includes(:project).recent
        scope = scope.where(level: level_filter) if level_filter.any?
        scope = scope.where(environment: filter_ids(:environment)) if filter_ids(:environment).any?
        # CYRA-355 — filtro per versione pubblicata: senza, «guarda solo l'ultimo rilascio» — la
        # domanda del giorno in cui si è appena pubblicato — si poteva solo cercare a testo.
        scope = scope.where(release: filter_ids(:release)) if filter_ids(:release).any?
        scope = filter_by_project(scope)
        # CYRA-60: filtro trace_id ESATTO (indice [project_id, trace_id]), distinto dalla search q= che fa
        # anche message ILIKE su tutto lo stream visibile. È il pivot dalla show errore verso "tutti i log
        # di QUESTA richiesta": deve mostrare esattamente i log del trace (nessun log estraneo che
        # menziona il trace nel messaggio, nessun altro progetto), coerente col badge "N log correlati"
        # che conta per [progetto, trace]. Il link passa anche project_id → scoping identico al badge.
        scope = scope.where(trace_id: params[:trace_id]) if params[:trace_id].present?
        # CYRA-56 → CYRA-340: la finestra per scopare a un incidente (es. 14:00–14:10) non è più due
        # campi sempre aperti solo di questa pagina, ma il periodo dell'area — scelte rapide uguali a
        # errori e prestazioni, e le due date a mano sotto «Personalizzato». Estremi indipendenti e
        # inclusivi; occurred_at è indicizzato ([project_id, occurred_at]). since=today (deep-link dal
        # KPI della dashboard) è già un periodo, e come tale lo tratta #current_time_range.
        @range_from = current_time_range.from
        @range_to = current_time_range.to
        scope = current_time_range.apply(scope, column: :occurred_at)
        scope = scope.where(created_at: ::Ingest::EpochTime.insert_floor(@range_from)..) if @range_from
        # Ricerca su message (ILIKE) O trace_id esatto (sfrutta l'indice [project_id, trace_id]): incollare
        # un trace_id copiato da un errore ricostruisce la richiesta.
        scope = filter_by_search(scope, "logs_entries.message", exact: "logs_entries.trace_id")

        # CYRA-344 — filtro su un campo strutturato: `data.<chiave>=<valore>`. È l'unico modo per
        # restringere per struttura invece di indovinare le parole nel messaggio.
        scope = scope.where("logs_entries.data ->> ? = ?", field_filter[:key], field_filter[:value]) if field_filter

        # CYRA-348 — il drill-down dalla vista raggruppata: le occorrenze di UNA impronta, con gli
        # stessi filtri addosso. Vive qui e non in un'azione a parte perché è la stessa lista.
        scope = scope.where(fingerprint: params[:fingerprint]) if params[:fingerprint].present?

        # Vista raggruppata (spenta di partenza, e la scelta resta nell'indirizzo): una riga per
        # messaggio invece di una per occorrenza. Su ventimila righe è l'unico modo per sapere quanti
        # problemi diversi ci siano davvero.
        # CYRA-578 — sfogliabile come la lista, e con gli stessi filtri: fermarsi ai primi cinquanta
        # gruppi senza dirlo nascondeva proprio i messaggi nuovi (i gruppi piccoli), e per restringere
        # a un progetto bisognava spegnere il raggruppamento perdendo il punto in cui si era.
        @grouped = params[:grouped] == "1"
        if @grouped
          @group_pagination = Logs::GroupedMessages.call(scope: scope, page: params[:page],
                                                         per: requested_per(Pagination::DEFAULT_PER))
          @groups = @group_pagination.records
        end

        # La vista raggruppata ha già i propri risultati: non caricare anche una pagina di
        # occorrenze che non viene resa (con un secondo conteggio e tutti i payload JSON).
        @entries = @grouped ? [] : paginated(scope, columns: SORT_COLUMNS)
        # Colonne senza un solo valore nel risultato: non si rendono. Una colonna di trattini occupa
        # spazio in una tabella già stretta e dice che manca qualcosa senza dire cosa.
        @show_logger_column = @entries.any? { |entry| entry.logger_name.present? }

        # CYRA-821 — chi sfoglia o riordina ha chiesto SOLO l'elenco. Tutto ciò che segue vive fuori
        # dal frame e non cambia girando pagina: il grafico del volume, i campi della sidebar, le
        # chip dei conteggi, l'elenco degli ambienti, le viste salvate. Sono aggregati su una tabella
        # a fette da milioni di righe, e rifarli per riscrivere gli stessi numeri è il lavoro che
        # questo ritorno evita. Filtri, periodo e ricerca restano una navigazione intera: cambiano
        # l'insieme, e con esso quei numeri.
        if results_frame_request?
          assign_frame_retention_hint
          return render_results_frame
        end

        # Le righe più vecchie dell'impronta: lo dice la barra sopra l'elenco, che sta fuori dal frame.
        @ungrouped_count = scope.where(fingerprint: nil).count if @grouped

        # CYRA-354 — il volume nel tempo sopra l'elenco: senza, per capire cos'è successo alle tre di
        # notte servirebbe sfogliare migliaia di pagine. Riflette i filtri accesi, ed è sempre
        # limitato a una finestra — aggregare tutto lo stream a ogni caricamento renderebbe lenta
        # proprio la pagina che serve quando le cose vanno male.
        @chart_from, @chart_to = chart_window
        @volume_buckets = Logs::VolumeBuckets.call(scope: scope, from: @chart_from, to: @chart_to)
        # I tre conteggi in cima seguono il filtro (prima restavano identici, e sembrava che il
        # filtro non avesse avuto effetto): accanto resta il totale non filtrato, che è il contesto.
        assign_filtered_counts(scope)
        @field_filter = field_filter
        @facets = log_facets(scope)
        load_filter_projects(visible.projects.includes(:organization))
        # CYRA-822 — a quale segnale di aggiornamento si iscrive questa pagina: quello dei soli
        # progetti osservati quando il filtro ne seleziona alcuni, altrimenti quello unico
        # dell'organizzazione. Va dopo la tendina: legge da lì i progetti visibili.
        @live_projects = live_stream_projects
        @environments = cached_environments
        @saved_views = saved_views_for("log_entries")
        # CYRA-355 — viste già pronte per chi non ne ha nessuna: la funzione più utile su 55k righe
        # presuppone di sapere già quali sono le domande giuste, e queste sono quelle.
        @saved_view_presets = @saved_views.any? ? [] : log_view_presets
        # CYRA-340 — elenco vuoto: «non è ancora arrivato niente» o «il periodo non lascia passare
        # nulla»? Sono due frasi diverse, e la seconda ha una via d'uscita. Una query solo se serve.
        @has_filtered_records = @filtered_total.positive?
        @has_records = @has_filtered_records || visible.logs.exists?
        assign_level_counts
        assign_retention_hint
      end

      def show
        @related = related_logs
        @related_errors = related_errors
        # Conteggi REALI del trace (non i sotto-insiemi cappati sotto): alimentano il badge "quante voci
        # condividono questa richiesta" e il link di pivot allo stream filtrato (CYRA-345). @related_logs_count
        # include QUESTA voce — è un log della richiesta — così "3 log" = tutti i log del trace.
        @related_logs_count = trace_scoped_logs.count
        @related_errors_count = trace_scoped_errors.count
        @links = @entry.links.includes(:linkable).order(:created_at)
        # CYRA-347 — il ticket nato da (o collegato a) questo messaggio: decide se mostrare il pulsante
        # «apri un ticket» o lo stato «già promosso». Letto dai link già caricati, nessuna query in più.
        @linked_ticket = @links.find { |link| link.linkable.is_a?(::Ticketing::Ticket) }&.linkable
      end

      private

      # CYRA-340 — `since=today` è il deep-link dal riquadro «oggi» della dashboard: è già un periodo,
      # dichiarato con un'altra parola. Tradurlo in un personalizzato che parte da stanotte tiene
      # insieme le due cose — il numero della card e l'elenco continuano a combaciare, e il periodo
      # ricordato non si intromette rimpicciolendo la giornata a ventiquattro ore mobili.
      def current_time_range
        return super unless params[:since] == "today"

        # `::` obbligatorio: siamo dentro Member::Monitoring, dove `Monitoring::` risolverebbe
        # sul namespace del controller invece che sul modello.
        @current_time_range ||= ::Monitoring::TimeRange.resolve(
          key: ::Monitoring::TimeRange::CUSTOM, from: Time.current.beginning_of_day.iso8601
        )
      end

      def time_range_declared? = super || params[:since].present?

      # I campi presenti nel risultato, coi valori più frequenti. Calcolati su una FINESTRA (le ultime
      # FACET_WINDOW righe del filtro corrente), non su tutto lo stream: su 55k+ voci una scansione a
      # ogni caricamento costerebbe più di quanto vale la sidebar. Il conteggio dichiara la finestra.
      FACET_WINDOW = 500
      FACET_TOP_VALUES = 5

      def log_facets(scope)
        rows = scope.reorder(occurred_at: :desc).limit(FACET_WINDOW).pluck(:data)
        counts = Hash.new { |hash, key| hash[key] = Hash.new(0) }
        rows.each do |data|
          next unless data.is_a?(Hash)

          data.each do |key, value|
            next if value.nil? || value.is_a?(Hash) || value.is_a?(Array)

            counts[key][value.to_s] += 1
          end
        end
        counts.sort_by { |key, _| key }.map do |key, values|
          { key: key, values: values.sort_by { |value, count| [ -count, value ] }.first(FACET_TOP_VALUES) }
        end
      end

      # CYRA-821 — il frame in cui vivono i risultati: sfogliare e riordinare chiedono solo lui.
      def results_frame_id = "logs-results"

      # L'unica cosa del contesto che il frame rende è la nota sulla conservazione, e solo nel
      # riquadro «nessun risultato»: si legge lì e da nessun'altra parte dentro il frame. La nota
      # parte dai progetti della tendina, che fuori dal frame non si caricano.
      def assign_frame_retention_hint
        return unless @entries.empty? && !@grouped

        load_filter_projects(visible.projects.includes(:organization))
        assign_retention_hint
      end

      # Un filtro per volta, quello scritto nell'URL: `field=chiave` + `value=valore`.
      def field_filter
        return nil if params[:field].blank? || params[:value].blank?

        { key: params[:field].to_s, value: params[:value].to_s }
      end


      # Dropdown environment: DISTINCT su TUTTO lo stream visibile (non filtrato dai filtri di lista).
      # Servito dall'indice [project_id, environment] (index-only scan) e cache-ato con TTL breve keyed
      # sui progetti visibili, così render ripetuti dello stesso scope non ri-scansionano il DB (CYRA-59).
      def cached_environments
        Rails.cache.fetch(facets_cache_key(:environments), expires_in: Logs::Constants::FACETS_CACHE_TTL) do
          visible.logs.distinct.pluck(:environment).compact.sort
        end
      end

      # Riga chip header: conteggi globali per livello (scope progetti visibili, non filtrato — come
      # error_groups). Una GROUP BY level servita dall'indice [project_id, level], cache-ata con TTL breve
      # keyed sui progetti visibili (CYRA-59): due aggregati sull'intero stream (decine di milioni di
      # righe) non vanno rieseguiti a ogni apertura/paginazione/filtro. Le chiavi di group(:level).count
      # possono essere int o label a seconda di Rails → normalizzate a label prima di cache-are.
      # CYRA-354 — la finestra del grafico: quella scelta con from/to, oppure le ultime 24 ore. Non
      # esiste un grafico "su tutto": senza un limite l'aggregazione cresce col volume e la pagina
      # rallenta proprio quando serve.
      DEFAULT_CHART_SPAN = 24.hours

      def chart_window
        to = @range_to || Time.current
        from = @range_from || (params[:since] == "today" ? Time.current.beginning_of_day : to - DEFAULT_CHART_SPAN)
        from < to ? [ from, to ] : [ to - DEFAULT_CHART_SPAN, to ]
      end

      # Conteggi sul risultato filtrato. Una sola aggregazione per livello, come quella non filtrata:
      # tre count separati sarebbero tre scansioni dello stesso scope.
      # Le tre domande che si fanno tutti davanti a 55k righe: cosa è andato storto di recente, cosa
      # è andato storto in modo grave, e cosa succede sulla versione appena pubblicata.
      #
      # «ultime 24 ore» è un istante calcolato ADESSO, a ogni caricamento: una vista pronta con una
      # data fissa dentro invecchierebbe il giorno dopo. La vista dell'ultima versione compare solo
      # se una versione c'è: una vista che non può che dare zero risultati sembra rotta.
      def log_view_presets
        presets = [
          { key: "recent_errors", name: t("shared.saved_views.preset_logs_recent_errors"),
            filters: { "level" => %w[error fatal], "from" => 24.hours.ago.iso8601 } },
          { key: "fatal", name: t("shared.saved_views.preset_logs_fatal"),
            filters: { "level" => [ "fatal" ] } }
        ]
        latest = latest_release
        if latest.present?
          presets << { key: "latest_release", name: t("shared.saved_views.preset_logs_latest_release", release: latest),
                       filters: { "release" => [ latest ] } }
        end
        presets
      end

      # L'ultima versione che ha scritto qualcosa, letta dalla finestra recente: leggerla da tutto lo
      # stream costerebbe una scansione a ogni caricamento per una riga di menu.
      def latest_release
        since = 7.days.ago
        visible.logs.where(occurred_at: since.., created_at: ::Ingest::EpochTime.insert_floor(since)..)
                    .where.not(release: nil).order(occurred_at: :desc).limit(1).pick(:release)
      end

      def assign_filtered_counts(scope)
        by_level = scope.reorder(nil).group(:level).count
                           .transform_keys { |k| k.is_a?(Integer) ? Logs::Entry.levels.key(k) : k.to_s }
        @filtered_total = by_level.values.sum
        @filtered_error_count = by_level.values_at("error", "fatal").compact.sum
        @filtered_warning_count = by_level.fetch("warning", 0)
      end

      def assign_level_counts
        by_level = Rails.cache.fetch(facets_cache_key(:level_counts), expires_in: Logs::Constants::FACETS_CACHE_TTL) do
          visible.logs.group(:level).count
                              .transform_keys { |k| k.is_a?(Integer) ? Logs::Entry.levels.key(k) : k.to_s }
        end
        @logs_total = by_level.values.sum
        @logs_error_count = by_level.values_at("error", "fatal").compact.sum
        @logs_warning_count = by_level.fetch("warning", 0)
        # CYRA-350 — la stessa aggregazione serve al filtro: ogni livello dice quante voci ha, e
        # quelli a zero non si possono scegliere. Sceglierli portava a una pagina vuota e muta.
        @level_counts = ::Logs::Entry.levels.keys.index_with { |level| by_level.fetch(level, 0) }
      end

      # Nota retention (CYRA-61): la pagina Logs è cross-app ma la retention è per-progetto (nearest-wins
      # progetto → org → god → default). Comunica la finestra sui progetti visibili (o sui soli filtrati per
      # project_id): @logs_retention = { min:, max: } — un solo numero se coincidono, un range altrimenti;
      # nil se l'utente non vede alcun progetto (niente da comunicare). Serve a spiegare uno stream vuoto o
      # un log purgato, evitando il "i log non arrivano" (ticket di supporto). org+global sono uguali per
      # tutti i progetti visibili (stessa org) → global pre-risolto una volta e organization preloaded:
      # niente N+1 su Settings::Global / project.organization.
      def assign_retention_hint
        projects = @projects.to_a
        projects = projects.select { |p| filter_ids(:project_id).include?(p.id) } if filter_ids(:project_id).any?
        return @logs_retention = nil if projects.empty?

        global = Logs::Retention.resolve(Settings::Global.instance.logs_retention_days)
        days = projects.map { |p| Logs::Retention.for(p, global_days: global) }
        @logs_retention = { min: days.min, max: days.max }
      end

      # Chiave cache dei facet, stabile e per-scope: dipende SOLO dall'insieme dei progetti visibili
      # (set diverso → facet diversi → chiave diversa, niente leak cross-scope/BOLA). Gli id sono
      # ordinati e hashati così l'ordine non genera chiavi diverse per lo stesso set. Digest memoizzato
      # per richiesta (una sola query leggera su projects, non sui log).
      def facets_cache_key(facet)
        "logs:facets:#{facet}:#{visible_projects_digest}"
      end

      def visible_projects_digest
        @visible_projects_digest ||=
          Digest::SHA256.hexdigest(visible.projects.pluck(:id).sort.join(","))
      end

      # Anti-BOLA + scoping: log non visibile (altra org / progetto non assegnato) → RecordNotFound.
      def set_entry
        @entry = visible.logs.find(params[:id])
      end

      def level_filter = enum_filter(:level, Logs::Entry.levels.keys)

      # Tutti i log della stessa richiesta (stesso trace_id + progetto), QUESTA voce inclusa: base sia
      # del conteggio onesto sia della lista mostrata. Vuoto se il log non ha un trace_id.
      def trace_scoped_logs
        return Logs::Entry.none if @entry.trace_id.blank?

        visible.logs.where(project_id: @entry.project_id, trace_id: @entry.trace_id)
      end

      # Errori della stessa richiesta: correlazione via la colonna indicizzata trace_id, popolata da
      # Normalize sia dal trace_id top-level (gemma) sia da contexts.trace.trace_id (SDK Sentry).
      # La vecchia query payload->>'trace_id' era non indicizzata e perdeva gli errori Sentry-shaped.
      def trace_scoped_errors
        return Errors::Event.none if @entry.trace_id.blank?

        Errors::Event.where(project_id: @entry.project_id, trace_id: @entry.trace_id)
      end

      # Correlazione automatica: gli ALTRI log della richiesta (esclusa la voce corrente), cappati.
      def related_logs
        trace_scoped_logs.where.not(id: @entry.id).recent.limit(50)
      end

      # Errori della richiesta con il gruppo precaricato, ordine stabile, cappati per la card.
      def related_errors
        trace_scoped_errors.includes(:group).order(occurred_at: :desc).limit(20)
      end
    end
  end
end
