# frozen_string_literal: true

module Assistant
  module Tools
    # The availability checks of ONE project: which are up, which are down and since when, and the
    # uptime of the last 24 hours — the same figure the Uptime page shows.
    class ListMonitors < Base
      def self.declaration
        { name: "list_monitors",
          description: "Elenca i controlli di disponibilità di UN progetto: se ogni servizio risponde, " \
                       "da quando è giù, e la percentuale di disponibilità delle ultime 24 ore. " \
                       "Usalo per domande come 'CYRA è online?' o 'com'è la disponibilità?'.",
          parameters: {
            type: "OBJECT",
            properties: { project: { type: "STRING", description: "Chiave del progetto, es. CYRA" } },
            required: [ "project" ]
          } }
      end

      def call(args)
        project = context.find_project(args["project"])
        return not_visible(args["project"]) if project.nil?

        scope = ::Uptime::Monitor.where(project_id: project.id)
        monitors = scope.ordered.includes(:environment).limit(MAX_ROWS).to_a
        percents = ::Uptime::Monitor.uptime_percents(monitors.map(&:id), 24.hours.ago)
        down_since = open_incidents(monitors)

        { project: project.key, total: scope.count, showing: monitors.size,
          monitors: monitors.map { |monitor| row(monitor, percents, down_since) } }
      end

      private

      def open_incidents(monitors)
        ::Uptime::Incident.open.where(monitor_id: monitors.map(&:id)).group(:monitor_id).minimum(:started_at)
      end

      def row(monitor, percents, down_since)
        { name: monitor.name, environment: monitor.environment&.label, status: monitor.current_status,
          paused: !monitor.active, uptime_24h: percents[monitor.id],
          down_since: down_since[monitor.id]&.iso8601, last_checked: monitor.last_checked_at&.iso8601 }
      end
    end
  end
end
