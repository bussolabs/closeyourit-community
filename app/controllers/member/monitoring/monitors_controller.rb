# frozen_string_literal: true

module Member
  module Monitoring
    # Uptime monitoring (UI Member). Lettura per chi vede i progetti (scoping visible.monitors,
    # anti-BOLA); gestione (CRUD + pause/resume) per admin/owner. Query batch per evitare N+1 in lista.
    class MonitorsController < Member::BaseController
      permission_not_required "Controlli di raggiungibilità dei progetti visibili: sola lettura, la gestione è " \
                              "gated più sotto.",
                              only: %i[index show]

      # CYRA-737 — la base condivisa delle pagine-elenco dell'area di controllo.
      include Indexable
      # Chip up/down/monitors/incident-aperti dell'header, condivisi con la tab Incidents.
      include UptimeHeaderStats

      # Whitelist ordinamento (contratto Sortable#sorted). Uptime% e Response restano
      # statici: aggregati batch calcolati in memoria sui check, non colonne SQL.
      SORT_COLUMNS = {
        "monitor" => "LOWER(uptime_monitors.name)",
        "status" => :current_status,
        "last_check" => :last_checked_at
      }.freeze
      # CYRA-924 — computed per monitor, sorted in memory (see #index).
      COMPUTED_SORTS = %w[uptime response].freeze

      before_action :load_uptime_header_stats, only: :index
      before_action :set_monitor, only: %i[show edit update destroy pause resume publish unpublish]
      before_action :require_uptime, only: %i[new create edit update destroy pause resume publish unpublish]
      before_action :load_form_data, only: %i[new create edit update]

      # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
      remembers_filters :status, :project_id, :q, :sort, only: :index

      def index
        @range = range_param
        # Vista di default = raggruppata per gruppo uptime; ?view=table = tabella flat paginata.
        @view = params[:view] == "table" ? "table" : "grouped"
        since = Time.current - Uptime::Monitor.range_duration(@range)
        # Preload icona del gruppo (EntityMark nelle sezioni grouped) → niente N+1 su active_storage.
        scope = visible.monitors.includes(:project, :environment, group: { icon_image_attachment: :blob })
        # Filtro sullo stato MOSTRATO (display_status), non persistito: un monitor col dato vecchio è
        # mostrato "unknown", quindi va sotto quel filtro e non sotto up/down (CYRA-209).
        scope = scope.for_display_statuses(status_filter) if status_filter.any?
        scope = filter_by_project(scope)
        # Default (CYRA-492): i non sani in cima, poi per nome — con sessanta monitor il caduto non si
        # trova a occhio. `sorted` (reorder) subentra SOLO con un sort esplicito di colonna, così
        # l'ordinamento manuale resta intatto. @health_sorted = il default è in vigore → lo dichiara l'header.
        scope = scope.health_order.order(Arel.sql("LOWER(uptime_monitors.name)"))
        sorted_scope = sorted(scope, columns: SORT_COLUMNS)
        @health_sorted = SORT_COLUMNS[current_sort.first].nil? && !COMPUTED_SORTS.include?(current_sort.first)
        source = Uptime::Monitor.bucket_config(@range)[:source]
        if COMPUTED_SORTS.include?(current_sort.first)
          # CYRA-924 — uptime and response are computed from the checks: every visible monitor gets
          # its figures first, then the rows sort in memory and the table pages them.
          all = sorted_scope.to_a
          load_monitor_figures(all.map(&:id), since, source)
          all = sorted_rows(all, columns: computed_sort_columns)
          @monitors = @view == "table" ? paginated_rows(all) : all
        else
          # Raggruppata: mostra TUTTI i monitor visibili/filtrati (il raggruppamento ha senso
          # sull'insieme completo — la vista grouped non ha pager; la table resta paginata).
          @monitors = @view == "table" ? paginated(sorted_scope) : sorted_scope.to_a
          load_monitor_figures(@monitors.map(&:id), since, source)
        end
        ids = @monitors.map(&:id)
        # CYRA-492 — inizio del guasto in corso per i monitor giù, in batch (niente N+1 in lista):
        # { monitor_id => started_at } dall'incident aperto. La riga lo mostra come «Giù da 3h 09m».
        @open_since = ::Uptime::Incident.top_level.open.where(monitor_id: ids).pluck(:monitor_id, :started_at).to_h
        # F093 — why a monitor is down, on its row: the latest failed check of each one, in one query.
        @down_causes = ::Uptime::Check.raw.where(monitor_id: @open_since.keys, up: false)
                                      .select("DISTINCT ON (monitor_id) monitor_id, error, status_code")
                                      .order(:monitor_id, checked_at: :desc)
                                      .to_h { |check| [ check.monitor_id, check.error.presence || ("HTTP #{check.status_code}" if check.status_code) ] }

        # Chip header (@total/@up_count/@down_count/@open_incidents_count) da UptimeHeaderStats.
        # Il feed incident non vive più qui: è la tab Incidents (member_monitoring_incidents_path).
        @projects = visible.projects.order(:name)
        # CYRA-477: quanti siti sotto controllo sono coperti da una regola "Uptime down" e quanti no.
        @alert_coverage = Alerting::Coverage.for(organization: current_organization,
                                                 event_type: :uptime_down, entities: visible.monitors)
        @saved_views = saved_views_for("uptime")
      end

      def show
        @tab = params[:tab] == "public" ? "public" : "overview"
        @range = range_param
        source = Uptime::Monitor.bucket_config(@range)[:source]
        since = Time.current - Uptime::Monitor.range_duration(@range)
        @buckets = Uptime::Monitor.buckets_for([ @monitor.id ], @range)[@monitor.id]
        @incidents = @monitor.incidents.recent.limit(20).to_a
        # Tentativi recenti (lista live, prepend via stream del monitor in RecordCheck). Solo raw (associazione scoped).
        @checks = @monitor.checks.recent.limit(10).to_a
        @open_incident = @monitor.open_incident
        @uptime = uptime_percents([ @monitor.id ], since, source)[@monitor.id]
        # Avg response del range dalla stessa sorgente dei bucket (il raw copre solo le finestre brevi):
        # media pesata sugli up dei blocchi già caricati → vale anche per 7d/30d/1y.
        @avg_response = average_response(@buckets)
        windows = Uptime::Monitor::RANGES.keys.index_with { |key| Time.current - Uptime::Monitor.range_duration(key) }
        percents = Uptime::Monitor.uptime_percents_for_windows([ @monitor.id ], windows)[@monitor.id] || {}
        @sla = Uptime::Monitor::RANGES.keys.index_with { |key| percents[key] }
        # CYRA-476: chi verrà avvisato se questo sito cade — le regole uptime_down che lo intercettano
        # (progetto/ambiente). Materializza in vista la relazione monitor→regola prima solo runtime.
        @alerting_rules = Alerting::Coverage.rules_for(monitor: @monitor)
      end

      def new
        @monitor = Uptime::Monitor.new(prefill_params)
      end

      def create
        # Logica condivisa col canale CLI in Uptime::Monitors::Save: project/environment risolti qui
        # (scope visibile) e fissati alla creazione; name auto-derivato dal model.
        @monitor = Uptime::Monitor.new
        result = Uptime::Monitors::Save.call(
          monitor: @monitor, attributes: monitor_params,
          project: visible.projects.find_by(id: params[:project_id]),
          environment_id: params[:environment_id], group_id: params[:group_id], actor: Current.account
        )
        if result.ok?
          redirect_to member_monitoring_monitor_path(@monitor), notice: t("member.uptime.created")
        else
          @errors = @monitor.errors.to_hash
          render :new, status: :unprocessable_content
        end
      end

      def edit; end

      def update
        # progetto ed environment sono immutabili dopo la creazione (1 monitor per [progetto, env]);
        # il gruppo invece è mutabile (passato sempre dal form: blank = nessun gruppo).
        result = Uptime::Monitors::Save.call(monitor: @monitor, attributes: monitor_params, group_id: params[:group_id])
        if result.ok?
          redirect_to member_monitoring_monitor_path(@monitor), notice: t("member.uptime.updated")
        else
          @errors = @monitor.errors.to_hash
          render :edit, status: :unprocessable_content
        end
      end

      def destroy
        @monitor.destroy
        redirect_to member_monitoring_monitors_path, notice: t("member.uptime.deleted")
      end

      def pause  = toggle_active(false, :paused)
      def resume = toggle_active(true, :resumed)

      # Status page pubblica (opt-in): attiva/disattiva il flag public_status_enabled del monitor.
      def publish   = toggle_public(true, :published)
      def unpublish = toggle_public(false, :unpublished)

      private

      def load_monitor_figures(ids, since, source)
        @uptime = uptime_percents(ids, since, source)
        @buckets = Uptime::Monitor.buckets_for(ids, @range)
      end

      # The row shows the latest bucket with an average: the sort reads the same value.
      def computed_sort_columns
        {
          "uptime" => ->(monitor) { @uptime[monitor.id] },
          "response" => ->(monitor) { Array(@buckets[monitor.id]).reverse.find { |bucket| bucket[:avg_ms] }&.dig(:avg_ms) }
        }
      end

      def toggle_active(active, key)
        @monitor.update!(active: active)
        redirect_to member_monitoring_monitor_path(@monitor), notice: t("member.uptime.#{key}")
      end

      # update_column (non update!): il flag pubblico è una preferenza indipendente, non deve essere
      # bloccato da validazioni estranee del monitor (es. un progetto che ha perso la piattaforma
      # web → project_supports_uptime fallirebbe). Stesso pattern dei toggle-switch del progetto.
      def toggle_public(enabled, key)
        @monitor.update_column(:public_status_enabled, enabled)
        redirect_to member_monitoring_monitor_path(@monitor, tab: "public"), notice: t("member.uptime.#{key}")
      end

      # Anti-BOLA + scoping: monitor non visibile → RecordNotFound. Preload project(+organization) ed
      # environment: la show li usa (nome/env, link pubblico, turbo_stream via project) → evita query
      # lazy in view e strict-loading violation.
      def set_monitor
        @monitor = visible.monitors.includes(:environment, :group, project: :organization).find(params[:id])
      end

      def load_form_data
        # Solo progetti uptime-capable (piattaforma web/server): i monitor non esistono sui solo-mobile.
        # Solo quelli gestibili (uptime.manage): non si offrono target su cui il submit verrebbe negato,
        # e il reload del turbo-frame environment (via new?project_id=X) è sempre permesso.
        # Environment e capability precaricati (CYRA-747): il form li legge sul progetto scelto per
        # comporre la tendina, e senza preload sono due query in più ogni volta che la tendina si
        # ricarica al cambio di progetto.
        @projects = visible.projects.uptime_capable.order(:name)
                      .includes(:project_environments, :environments)
                      .select { |p| can?("uptime.manage", scope: p) }
        # Gruppi assegnabili (org-level): il monitor può stare in un gruppo uptime, opzionale.
        @uptime_groups = Current.organization.uptime_groups.ordered.to_a
      end

      # name escluso: è auto-derivato (progetto · environment), il form non lo raccoglie.
      def monitor_params
        params.permit(:check_type, :url, :host, :port, :http_method, :interval_seconds, :expected_status,
                      :timeout_seconds, :expected_body_keyword, :ssl_expiry_warn_days, :latency_threshold_ms,
                      :failure_threshold)
      end

      def prefill_params
        { check_type: "http", interval_seconds: 60, expected_status: 200, timeout_seconds: 5, http_method: "GET" }
      end

      def range_param
        Uptime::Monitor::RANGES.key?(params[:range]) ? params[:range] : Uptime::Monitor::DEFAULT_RANGE
      end

      def status_filter = enum_filter(:status, Uptime::Monitor.current_statuses.keys)

      def uptime_percents(ids, since, source) = Uptime::Monitor.uptime_percents(ids, since, source: source)

      # Avg response del range = media pesata sugli up dei blocchi (nil se nessun up). Deriva dai @buckets
      # già calcolati dalla sorgente giusta (raw/hourly/daily), così non ri-query il raw (potato oltre 3gg).
      def average_response(buckets)
        total_up = buckets.sum { |b| b[:up] }
        return nil if total_up.zero?

        (buckets.sum { |b| b[:avg_ms].to_i * b[:up] }.to_f / total_up).round
      end

      # uptime.manage scoped al progetto del monitor (azioni su monitor esistente) o al progetto
      # target (create via params[:project_id]). FAIL-CLOSED: il default è NEGARE. L'unica eccezione
      # è il form `new` vuoto (nessuno scope), ammesso solo a chi può gestire uptime su almeno un
      # progetto visibile. Ogni altro caso senza scope risolvibile → require_permission! con scope nil
      # (permesso scoped + scope nil → il Resolver nega).
      def require_uptime
        scope = @monitor&.project || visible.projects.find_by(id: params[:project_id])
        if scope
          require_permission!("uptime.manage", scope: scope)
        elsif action_name == "new" && visible.projects.any? { |p| can?("uptime.manage", scope: p) }
          nil # form vuoto: ok, può creare monitor su almeno un progetto
        else
          require_permission!("uptime.manage", scope: nil) # nega (scope nil)
        end
      end
    end
  end
end
