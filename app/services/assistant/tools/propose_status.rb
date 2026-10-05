# frozen_string_literal: true

module Assistant
  module Tools
    # Proposes a status change; an unknown name returns the valid ones (CYRA-907).
    class ProposeStatus < ProposalTool
      def self.declaration
        { name: "propose_status",
          description: "Proposes moving a ticket to another status. The user confirms it.",
          parameters: {
            type: "OBJECT",
            properties: { code: { type: "STRING", description: "Ticket code, e.g. CYRA-279" },
                          status: { type: "STRING", description: "Target status name, e.g. Done" } },
            required: %w[code status]
          } }
      end

      def call(args)
        ticket = context.find_ticket(args["code"])
        return { error: "Nessun ticket visibile con codice #{args['code']}." } if ticket.nil?

        status = find_type(statuses, args["status"])
        return { error: "Stato sconosciuto. Stati validi: #{statuses.map(&:display_label).join(', ')}." } if status.nil?

        propose(:change_ticket_status, ticket_id: ticket.id, ticket_code: ticket.code, ticket_title: ticket.title,
                                       status_id: status.id, status_label: status.display_label,
                                       from_label: ticket.status&.display_label)
      end
    end
  end
end
