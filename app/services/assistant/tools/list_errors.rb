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
          description: "Elenca gli errori di UN progetto: titolo, livello, quante volte è successo, " \
                       "quando l'ultima volta, in quale versione e l'eventuale ticket collegato. " \
                       "Usalo per domande come 'quali errori ha CYRA?' o 'cosa si è rotto oggi?'.",
          parameters: {
            type: "OBJECT",
            properties: {
              project: { type: "STRING", description: "Chiave del progetto, es. CYRA" },
              status: { type: "STRING", enum: STATUSES,
                        description: "unresolved = da risolvere (default), resolved = risolti, ignored = ignorati" }
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
