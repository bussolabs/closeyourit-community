# frozen_string_literal: true

module Assistant
  module Tools
    # Proposes an assignee among the organization members; "me" means the person asking (CYRA-907).
    class ProposeAssignee < ProposalTool
      SELF_WORDS = %w[me io mi myself].freeze

      def self.declaration
        { name: "propose_assignee",
          description: "Proposes assigning a ticket to a member (\"me\" for the person asking). The user confirms it.",
          parameters: {
            type: "OBJECT",
            properties: { code: { type: "STRING", description: "Ticket code, e.g. CYRA-279" },
                          assignee: { type: "STRING", description: "Member name or email, or me" } },
            required: %w[code assignee]
          } }
      end

      def call(args)
        ticket = context.find_ticket(args["code"])
        return { error: "Nessun ticket visibile con codice #{args['code']}." } if ticket.nil?

        assignee = find_member(args["assignee"])
        return { error: "Nessun membro corrisponde a #{args['assignee']}." } if assignee.nil?

        propose(:assign_ticket, ticket_id: ticket.id, ticket_code: ticket.code, ticket_title: ticket.title,
                                assignee_id: assignee.id, assignee_name: assignee.name)
      end

      private

      def find_member(reference)
        wanted = reference.to_s.strip
        return context.account if SELF_WORDS.include?(wanted.downcase)
        return nil if wanted.blank?

        like = "%#{Accounts::Account.sanitize_sql_like(wanted)}%"
        context.organization.accounts.where("accounts.name ILIKE :q OR accounts.email ILIKE :q", q: like).first
      end
    end
  end
end
