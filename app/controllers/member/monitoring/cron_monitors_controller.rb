# frozen_string_literal: true

module Member
  module Monitoring
    # Cron / heartbeat monitoring (UI Member): elenco dei job che fanno check-in e il loro stato
    # (ok/late/missed). La lettura è per chiunque veda i progetti (scoping anti-BOLA).
    #
    # CYRA-484 — la gestione (nome, cadenza, tolleranza, pausa, eliminazione) è gated da
    # uptime.manage sul progetto, come i monitor uptime: sono la stessa famiglia di controlli e non
    # avrebbe senso proteggerli con due chiavi diverse. La CREAZIONE resta al primo check-in: un
    # lavoro programmato esiste perché batte, non perché qualcuno lo ha dichiarato.
    class CronMonitorsController < Member::BaseController
      permission_not_required "Elenco dei lavori programmati e istruzioni per collegarli: sola lettura dei " \
                              "progetti visibili.",
                              only: %i[index setup]

      # CYRA-737 — la base condivisa delle pagine-elenco dell'area di controllo.
      include Indexable

      # Whitelist ordinamento (contratto Sortable#sorted).
      SORT_COLUMNS = {
        "name" => "LOWER(crons_monitors.name)",
        "project" => { expr: "LOWER(projects.name)", joins: :project },
        "interval" => :expected_interval_minutes,
        "status" => :status,
        "last_check_in" => :last_check_in_at
      }.freeze

      before_action :set_monitor, only: %i[show edit update destroy]
      before_action :require_manage, only: %i[edit update destroy]

      # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
      remembers_filters :status, :project_id, :q, :sort, only: :index

      def index
        scope = visible.cron_monitors.includes(:project, :environment).recent
        scope = scope.where(status: status_filter) if status_filter.any?
        scope = filter_by_project(scope)
        scope = filter_by_search(scope, "crons_monitors.name", "crons_monitors.slug")
        @monitors = paginated(scope, columns: SORT_COLUMNS)
        load_filter_projects

        monitors = visible.cron_monitors
        @ok_count = monitors.status_ok.count
        @missed_count = monitors.status_missed.count
        @failing_count = monitors.status_failing.count
        # CYRA-477: quanti cron sono coperti da una regola "Cron mancato" e quanti no. Senza copertura
        # un job che si ferma non avvisa nessuno — la pagina lo dichiara e offre di creare la regola.
        @alert_coverage = Alerting::Coverage.for(organization: current_organization,
                                                 event_type: :cron_missed, entities: monitors)
        @saved_views = saved_views_for("cron_monitors")
      end

      CHECK_IN_SORT_COLUMNS = {
        "status" => ->(check_in) { check_in.status },
        "duration" => ->(check_in) { check_in.duration_ms },
        "reason" => ->(check_in) { check_in.reason.to_s.downcase.presence },
        "at" => ->(check_in) { check_in.checked_in_at }
      }.freeze

      def show
        # CYRA-924 — the last fifty, sorted on any column (C9); the outage history reads its own rows.
        @check_ins = sorted_rows(@monitor.check_ins.recent.limit(50).to_a, columns: CHECK_IN_SORT_COLUMNS)
        # CYRA-484 — «da quanto dura questo stato»: chi guarda non deve contare i giorni da solo.
        @status_since = @monitor.status_since
        # I guasti passati, ricostruiti dai check-in: una serie di fallimenti consecutivi è UN guasto,
        # non venti righe. Senza, la pagina resta un elenco piatto in cui non si vede la storia.
        @incidents = ::Crons::IncidentHistory.call(monitor: @monitor)
        @can_manage = can?("uptime.manage", scope: @monitor.project)
      end

      # CYRA-485 — le istruzioni per mettere sotto controllo un lavoro. Non c'è una creazione da
      # qui (il monitor nasce al primo check-in), quindi questa pagina È il punto di partenza: senza,
      # la funzione restava invisibile a chi non l'aveva già configurata da fuori.
      def setup
        @projects = visible.projects.order(:name)
        @project = @projects.find { |p| p.id == params[:project_id] } || @projects.first
      end

      def edit; end

      def update
        if @monitor.update(monitor_params)
          redirect_to member_monitoring_cron_monitor_path(@monitor), notice: t("member.crons.updated")
        else
          @errors = @monitor.errors.to_hash
          render :edit, status: :unprocessable_content
        end
      end

      # Eliminare un lavoro programmato NON lo spegne: se continua a battere rinasce al prossimo
      # check-in, con la configurazione di partenza. Il testo di conferma lo dice.
      def destroy
        @monitor.destroy
        redirect_to member_monitoring_cron_monitors_path, notice: t("member.crons.deleted")
      end

      private

      def require_manage = require_permission!("uptime.manage", scope: @monitor.project)

      def monitor_params
        params.permit(:name, :expected_interval_minutes, :grace_minutes)
      end

      def set_monitor
        @monitor = visible.cron_monitors.find(params[:id])
      end

      def status_filter = enum_filter(:status, Crons::Monitor.statuses.keys)
    end
  end
end
