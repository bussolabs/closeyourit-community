# frozen_string_literal: true

module Assistant
  module Tools
    # The availability checks of ONE project: which are up, which are down and since when, and the
    # uptime of the last 24 hours — the same figure the Uptime page shows.
    class ListMonitors < Base
      def self.declaration
        { name: "list_monitors",
          description: "Lists the uptime checks of ONE project: whether each service answers, " \
                       "since when it is down, and the uptime percentage of the last 24 hours. " \
                       "Use it for questions like 'is CYRA online?' or 'how is the uptime?'.",
          parameters: {
            type: "OBJECT",
            properties: { project: { type: "STRING", description: "Project key, e.g. CYRA" } },
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
