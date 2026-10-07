# frozen_string_literal: true

module Member
  # CYAU-235 — the supporter's decision behind an answer, loaded once per ticket for the whole page.
  module SupporterDecisionsHelper
    def supporter_decision_for(question)
      @supporter_decisions ||= {}
      @supporter_decisions[question.ticket_id] ||= ::Agents::SupporterDecision
        .where(target_type: "question", outcome: "answered",
               target_id: ::Ticketing::Question.where(ticket_id: question.ticket_id).select(:id))
        .index_by(&:target_id)
      @supporter_decisions[question.ticket_id][question.id]
    end
  end
end
