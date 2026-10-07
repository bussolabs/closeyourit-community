module Coworkers
  # Decides what happens to an action a Puck proposed: deny wins, sensitive actions always ask,
  # then the Puck's rule, and ask when there is none (CYRA-1017).
  module Policy
    Decision = Data.define(:decision, :rule)

    def self.decide(proposal, puck)
      return Decision.new(decision: "deny", rule: nil) unless Assistant::Proposal.kinds.key?(proposal.kind)

      rule = puck.rules.find_by(action: proposal.kind)
      return Decision.new(decision: "deny", rule: rule) if rule&.decision == "deny"
      return Decision.new(decision: "ask", rule: rule) if sensitive?(proposal)

      Decision.new(decision: rule&.decision || "ask", rule: rule)
    end

    # Closing a ticket cannot be undone by the Puck itself, and handing a ticket to the automation
    # starts work that writes code: both always wait for a person.
    def self.sensitive?(proposal)
      return true if proposal.kind_start_agent_work?
      return false unless proposal.kind_change_ticket_status?

      Types::TicketStatus.find_by(id: proposal.payload["status_id"])&.category_done? != false
    end
  end
end
