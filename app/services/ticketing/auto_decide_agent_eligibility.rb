# frozen_string_literal: true

module Ticketing
  # CYRA-1197 — on a project with the supporter on, the AI's advice becomes the decision, so a well-written ticket
  # reaches the agents without a person. The server's own checks stay in front: a ticket that hits a reserved topic
  # (money, security, deletions, plus the organization's and the project's) or
  # proposes to skip the system's gates stays pending for a person. A person's decision is never touched, and the
  # decision follows a later advice only while no person has decided.
  class AutoDecideAgentEligibility < ApplicationService
    def initialize(ticket:)
      @ticket = ticket
    end

    def call
      return Result.ok(nil) unless decidable?
      return Result.ok(nil) if @ticket.agent_eligibility == @ticket.agent_eligibility_advice
      return hold_for_a_person if @ticket.agent_eligibility_advice_allowed? && needs_a_person?

      from = @ticket.agent_eligibility
      ApplicationRecord.transaction do
        @ticket.update!(agent_eligibility: @ticket.agent_eligibility_advice,
                        agent_eligibility_reason: @ticket.agent_eligibility_advice_reason,
                        agent_eligibility_decided_at: Time.current, agent_eligibility_decided_by: nil)
        RecordActivity.call(ticket: @ticket, action: "agent_eligibility_overridden",
                            actor_name: I18n.t("agents.supporter.activity_actor"),
                            data: { agent_eligibility: { from:, to: @ticket.agent_eligibility } })
      end
      # CYRA-1364 — work the machines set aside starts over on its own, up to the per-ticket cap.
      Agents::Workflows::ResumeSetAside.call(ticket: @ticket, by_server: true) if @ticket.agent_eligibility_allowed?
      Result.ok(@ticket)
    end

    private

    def decidable?
      @ticket.agent_eligibility_source_automatic? && !@ticket.agent_eligibility_advice_unknown? &&
        @ticket.project.supporter_enabled?
    end

    def needs_a_person?
      reserved_matches.any? || bypass_matches.any?
    end

    def text = [ @ticket.title, @ticket.description, @ticket.technical_analysis ].join("\n")

    def reserved_matches
      @reserved_matches ||= Agents::Supporters::ReservedTopics
                            .new(organization: @ticket.project.organization, project: @ticket.project).match(text:)
    end

    def bypass_matches = @bypass_matches ||= Agents::Supporters::BypassGuard.match(text)

    # CYRA-1340 — the decision stays pending, but the ticket says why instead of waiting in silence.
    def hold_for_a_person
      reason = I18n.with_locale(@ticket.reporter&.effective_locale || I18n.default_locale) { hold_reason }
      @ticket.update!(agent_eligibility_reason: reason) unless @ticket.agent_eligibility_reason == reason
      Result.ok(nil)
    end

    def hold_reason
      return I18n.t("agents.supporter.held_for_person.bypass") if reserved_matches.empty?

      topics = reserved_matches.map { |entry| I18n.t("agents.supporter.held_for_person.topics.#{entry.topic || "listed"}") }
      I18n.t("agents.supporter.held_for_person.reserved", topics: topics.uniq.to_sentence,
                                                          words: reserved_matches.map(&:value).uniq.first(3).join(", "))
    end
  end
end
