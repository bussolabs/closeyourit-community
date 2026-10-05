# frozen_string_literal: true

module Assistant
  module Tools
    # Base of the write tools: they resolve their arguments inside the scope and save a pending
    # proposal on the reply; the user's click runs the action (CYRA-907).
    class ProposalTool < Base
      private

      def propose(kind, payload)
        proposal = Assistant::Proposal.create!(message: reply, organization: context.organization,
                                               account: context.account, kind: kind,
                                               payload: payload.deep_stringify_keys)
        { proposal_id: proposal.id, status: "awaiting_confirmation" }
      end

      def reply = @reply ||= Assistant::Message.find(context.reply_message_id)

      def statuses = context.organization.ticket_statuses.active.ordered
      def priorities = context.organization.ticket_priorities.active.ordered

      # Spoken names are approximate: match code or label, case-insensitive.
      def find_type(relation, name)
        wanted = name.to_s.strip.downcase
        return nil if wanted.blank?

        relation.find { |row| [ row.code, row.label, row.display_label ].map { |v| v.to_s.downcase }.include?(wanted) }
      end
    end
  end
end
