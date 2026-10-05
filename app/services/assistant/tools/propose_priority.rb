# frozen_string_literal: true

module Assistant
  module Tools
    # Proposes a priority change (CYRA-907).
    class ProposePriority < ProposalTool
      def self.declaration
        { name: "propose_priority",
          description: "Proposes changing the priority of a ticket. The user confirms it.",
          parameters: {
            type: "OBJECT",
            properties: { code: { type: "STRING", description: "Ticket code, e.g. CYRA-279" },
                          priority: { type: "STRING", description: "Priority name, e.g. High" } },
            required: %w[code priority]
          } }
      end

      def call(args)
        ticket = context.find_ticket(args["code"])
        return { error: "Nessun ticket visibile con codice #{args['code']}." } if ticket.nil?

        priority = find_type(priorities, args["priority"])
        return { error: "Priorità sconosciuta. Valide: #{priorities.map(&:display_label).join(', ')}." } if priority.nil?

        propose(:change_ticket_priority, ticket_id: ticket.id, ticket_code: ticket.code, ticket_title: ticket.title,
                                         priority_id: priority.id, priority_label: priority.display_label,
                                         from_label: ticket.priority&.display_label)
      end
    end
  end
end
