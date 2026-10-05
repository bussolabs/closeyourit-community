# frozen_string_literal: true

module Assistant
  module Tools
    # Proposes a new ticket; similar tickets ride along so the card can warn (CYRA-907).
    class ProposeTicket < ProposalTool
      KINDS = %w[bug story task].freeze

      def self.declaration
        { name: "propose_ticket",
          description: "Proposes a new ticket. The user confirms it on a card; nothing is created now.",
          parameters: {
            type: "OBJECT",
            properties: {
              project: { type: "STRING", description: "Project key or name, e.g. CYRA" },
              title: { type: "STRING", description: "One line, plain language" },
              description: { type: "STRING", description: "Two or three plain sentences" },
              kind: { type: "STRING", description: "bug, story or task (default bug)" },
              priority: { type: "STRING", description: "Priority name, optional" }
            },
            required: %w[project title description]
          } }
      end

      def call(args)
        project = context.find_project(args["project"])
        return not_visible(args["project"]) if project.nil?

        priority = find_type(priorities, args["priority"]) ||
                   priorities.find_by(id: Ticketing::FormOptions.default_priority_id(context.organization))
        propose(:create_ticket,
                project_id: project.id, project_key: project.key, title: args["title"].to_s.strip.first(255),
                description: args["description"].to_s.strip, ticket_kind: KINDS.include?(args["kind"]) ? args["kind"] : "bug",
                priority_id: priority&.id, priority_label: priority&.display_label,
                similar: similar(project, args))
      end

      private

      def similar(project, args)
        result = Ticketing::FindSimilarTickets.call(scope: context.tickets.where(project_id: project.id),
                                                    text: "#{args['title']} #{args['description']}")
        return [] if result.err?

        result.value.first(3).map { |match| { code: match.ticket.code, title: match.ticket.title } }
      end
    end
  end
end
