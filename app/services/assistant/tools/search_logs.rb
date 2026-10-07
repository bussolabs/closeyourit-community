# frozen_string_literal: true

module Assistant
  module Tools
    # The recent log lines of ONE project. Logs are a stream, not a list of things to fix: the
    # answer is a window (last hours), a count per level and the newest lines, cut short.
    class SearchLogs < Base
      DEFAULT_HOURS = 24
      # Logs are kept for a limited time; a wider window would only scan empty partitions.
      MAX_HOURS = 336
      MESSAGE_CHARS = 300

      def self.declaration
        { name: "search_logs",
          description: "Reads the recent logs of ONE project: how many per level and the newest lines. " \
                       "It can be narrowed to a minimum level or a text. " \
                       "Use it for questions like 'are there errors in the CYRA logs?' or 'what do the logs say about payment?'.",
          parameters: {
            type: "OBJECT",
            properties: {
              project: { type: "STRING", description: "Project key, e.g. CYRA" },
              level: { type: "STRING", enum: ::Logs::Entry.levels.keys,
                       description: "Minimum level: warning also includes error and fatal" },
              query: { type: "STRING", description: "Text to look for in the message" },
              hours: { type: "INTEGER", description: "How many hours back to look (default 24)" }
            },
            required: [ "project" ]
          } }
      end

      def call(args)
        project = context.find_project(args["project"])
        return not_visible(args["project"]) if project.nil?

        hours = window(args["hours"])
        scope = filtered(project, args, hours)
        rows = scope.recent.limit(MAX_ROWS).map { |entry| row(entry) }

        { project: project.key, hours: hours, total: scope.count, by_level: scope.group(:level).count,
          showing: rows.size, logs: rows }
      end

      private

      def window(value)
        hours = value.to_i
        hours.positive? ? [ hours, MAX_HOURS ].min : DEFAULT_HOURS
      end

      # A level the model made up is ignored, like an unknown status elsewhere: the full window is
      # still a true answer.
      def filtered(project, args, hours)
        scope = ::Logs::Entry.where(project_id: project.id, occurred_at: hours.hours.ago..)
        minimum = ::Logs::Entry.levels[args["level"].to_s]
        scope = scope.where(level: minimum..) if minimum
        query = args["query"].to_s.strip
        return scope if query.blank?

        scope.where("message ILIKE ?", "%#{::Logs::Entry.sanitize_sql_like(query)}%")
      end

      def row(entry)
        { at: entry.occurred_at.iso8601, level: entry.level, message: entry.message.to_s.first(MESSAGE_CHARS),
          logger: entry.logger_name, environment: entry.environment }
      end
    end
  end
end
