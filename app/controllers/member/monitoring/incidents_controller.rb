# frozen_string_literal: true

module Member
  module Monitoring
    # Tab Incidents di Monitor › Uptime: feed cross-monitor degli incident (finestre di downtime) dei
    # monitor visibili, paginato, con filtro stato aperti/risolti. Lettura per chi vede i progetti
    # (scoping visible.monitors, anti-BOLA); la gestione (grouping/timeline) resta nella show
    # del monitor. Top-level: i raggruppati collassano nel primary (parent_id nil).
    class IncidentsController < Member::BaseController
      permission_not_required "Disservizi dei monitor visibili: sola lettura, il confine è la visibilità dei " \
                              "progetti."

      # CYRA-737 — la base condivisa delle pagine-elenco dell'area di controllo.
      include Indexable
      include UptimeHeaderStats

      before_action :load_uptime_header_stats, only: :index

      # CYRA-694 — filtri ricordati (memoria per-indirizzo, vedi RememberableFilters).
      remembers_filters :status, :sort, only: :index

      # CYRA-924 — every column sorts (C9); an open incident lasts until now.
      SORT_COLUMNS = {
        # The Monitor column shows the monitor's project.
        "monitor" => "(SELECT LOWER(projects.name) FROM uptime_monitors JOIN projects ON projects.id = uptime_monitors.project_id " \
                     "WHERE uptime_monitors.id = uptime_incidents.monitor_id)",
        "started" => :started_at,
        "resolved" => :resolved_at,
        "duration" => "(COALESCE(uptime_incidents.resolved_at, CURRENT_TIMESTAMP) - uptime_incidents.started_at)",
        "status" => "(uptime_incidents.resolved_at IS NOT NULL)"
      }.freeze

      def index
        # Filtro progetto: la tab è cross-monitor, ma i deep-link (es. dashboard "Serve attenzione")
        # puntano a un progetto specifico. Gli incident non hanno project_id → si restringe via monitor.
        visible_monitors = filter_by_project(visible.monitors)
        scope = ::Uptime::Incident.top_level
                                  .includes(monitor: %i[project environment])
                                  .where(monitor_id: visible_monitors.select(:id))
                                  .recent
        # Filtro stato: aperti (resolved_at nil) / risolti. Param array (regola forms-select); entrambi
        # o nessuno = tutti. Il `&` mantiene solo i valori ammessi.
        states = enum_filter(:status, %w[open resolved])
        scope = scope.where(resolved_at: nil)     if states == %w[open]
        scope = scope.where.not(resolved_at: nil) if states == %w[resolved]
        @incidents = paginated(scope, columns: SORT_COLUMNS)
      end
    end
  end
end
