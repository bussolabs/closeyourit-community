# frozen_string_literal: true

module Ticketing
  # Approval requires current advice and a verified team creator, under the central writer lock.
  # Disabling the switch prevents new approvals but preserves earlier ones. Content changes
  # withdraw automatic approvals regardless of that switch. CYRA-1219.
  class AutoDecideAgentEligibility < ApplicationService
    def initialize(ticket:)
      @ticket = ticket
    end

    def call
      @ticket.with_lock do
        was_allowed = @ticket.agent_eligibility_allowed?
        result = SetAgentEligibility.call(ticket: @ticket, source: :go_ahead)
        if result.ok? && !was_allowed && @ticket.agent_eligibility_allowed?
          Agents::Workflows::ResumeSetAside.call(ticket: @ticket, by_server: true)
        end
        result
      end
    end

    # Called only by the central writer while holding the ticket lock. CYRA-1219.
    def attributes
      return {} unless @ticket.agent_eligibility_source_automatic?
      return decision(:pending, in_reporter_locale { I18n.t("agents.supporter.go_ahead_withdrawn") }) if withdrawable?
      return {} unless awaiting_go_ahead? && decidable?
      return { agent_eligibility_reason: in_reporter_locale { hold_reason } } if needs_a_person?

      decision(:allowed, @ticket.agent_eligibility_advice_reason)
    end

    private

    def awaiting_go_ahead?
      @ticket.agent_eligibility_pending? ||
        (@ticket.agent_eligibility_blocked? && Agents::Workflows::ExhaustedBudget.set_aside?(@ticket.agent_workflow))
    end

    def decidable?
      @ticket.agent_eligibility_advice_allowed? && !@ticket.agent_eligibility_stale? && switched_on? && from_the_team?
    end

    def switched_on? = @ticket.project.reload.auto_go_ahead_enabled?

    def from_the_team? = @ticket.team_authored?

    def withdrawable?
      @ticket.agent_eligibility_allowed? &&
        (@ticket.agent_eligibility_stale? || !@ticket.agent_eligibility_advice_allowed? || needs_a_person?)
    end

    def decision(eligibility, reason)
      { agent_eligibility: eligibility, agent_eligibility_reason: reason,
        agent_eligibility_decided_at: Time.current, agent_eligibility_decided_by: nil }
    end

    def needs_a_person?
      reserved_matches.any? || bypass_matches.any?
    end

    def text = AgentEligibilityText.call(ticket: @ticket)

    def reserved_matches
      @reserved_matches ||= Agents::Supporters::ReservedTopics
                            .new(organization: @ticket.project.organization, project: @ticket.project).match(text:)
    end

    def bypass_matches = @bypass_matches ||= Agents::Supporters::BypassGuard.match(text)

    def in_reporter_locale(&) = I18n.with_locale(@ticket.reporter&.effective_locale || I18n.default_locale, &)

    def hold_reason
      return I18n.t("agents.supporter.held_for_person.bypass") if reserved_matches.empty?

      topics = reserved_matches.map { |entry| I18n.t("agents.supporter.held_for_person.topics.#{entry.topic || "listed"}") }
      I18n.t("agents.supporter.held_for_person.reserved", topics: topics.uniq.to_sentence,
                                                          words: reserved_matches.map(&:value).uniq.first(3).join(", "))
    end
  end
end
