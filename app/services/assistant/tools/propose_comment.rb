# frozen_string_literal: true

module Assistant
  module Tools
    # Proposes a comment on a visible ticket (CYRA-907).
    class ProposeComment < ProposalTool
      def self.declaration
        { name: "propose_comment",
          description: "Proposes a comment on a ticket. The user confirms it; nothing is posted now.",
          parameters: {
            type: "OBJECT",
            properties: { code: { type: "STRING", description: "Ticket code, e.g. CYRA-279" },
                          body: { type: "STRING", description: "The comment text" } },
            required: %w[code body]
          } }
      end

      def call(args)
        ticket = context.find_ticket(args["code"])
        return { error: "Nessun ticket visibile con codice #{args['code']}." } if ticket.nil?

        propose(:comment_ticket, ticket_id: ticket.id, ticket_code: ticket.code, ticket_title: ticket.title,
                                 body: args["body"].to_s.strip)
      end
    end
  end
end
