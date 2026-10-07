# frozen_string_literal: true

module Assistant
  module Tools
    # The errors of ONE project, as the Errors page lists them: one row per deduplicated error,
    # newest first. Same status vocabulary as the page, so the count matches what is on screen.
    class ListErrors < Base
      STATUSES = %w[unresolved resolved ignored].freeze
      TITLE_CHARS = 160

      def self.declaration
        { name: "list_errors",
          description: "Lists the errors of ONE project: title, level, how many times it happened, " \
                       "when it last happened, in which release and the linked ticket if any. " \
                       "Use it for questions like 'which errors does CYRA have?' or 'what broke today?'.",
          parameters: {
            type: "OBJECT",
            properties: {
              project: { type: "STRING", description: "Project key, e.g. CYRA" },
              status: { type: "STRING", enum: STATUSES,
                        description: "unresolved = still to fix (default), resolved = fixed, ignored = ignored" }
            },
            required: [ "project" ]
          } }
      end

      def call(args)
        project = context.find_project(args["project"])
        return not_visible(args["project"]) if project.nil?

        status = STATUSES.include?(args["status"]) ? args["status"] : "unresolved"
        scope = ::Errors::Group.where(project_id: project.id, status: status)
        rows = scope.recent.includes(ticket: :project).limit(MAX_ROWS).map { |group| row(group) }

        { project: project.key, status: status, total: scope.count, showing: rows.size, errors: rows }
      end

      private

      def row(group)
        { title: group.title.to_s.first(TITLE_CHARS), level: group.level, events: group.events_count,
          users: group.users_count, last_seen: group.last_seen_at&.iso8601,
          release: group.release, ticket: group.ticket&.code }
      end
    end
  end
end
