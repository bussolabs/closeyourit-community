# frozen_string_literal: true

module Ticketing
  # CYRA-1197 — on a project with the supporter on, the AI's advice becomes the decision, so a well-written ticket
  # reaches the agents without a person. The server's own checks stay in front: a ticket that hits a reserved topic
  # (money, security, personal data, deletions, what customers see, plus the organization's and the project's) or
  # proposes to skip the system's gates stays pending for a person. A person's decision is never touched, and the
  # decision follows a later advice only while no person has decided.
  class AutoDecideAgentEligibility < ApplicationService
    def initialize(ticket:)
      @ticket = ticket
    end

    def call
      return Result.ok(nil) unless decidable?
      return Result.ok(nil) if @ticket.agent_eligibility == @ticket.agent_eligibility_advice
      return Result.ok(nil) if @ticket.agent_eligibility_advice_allowed? && needs_a_person?

      from = @ticket.agent_eligibility
      ApplicationRecord.transaction do
        @ticket.update!(agent_eligibility: @ticket.agent_eligibility_advice,
                        agent_eligibility_reason: @ticket.agent_eligibility_advice_reason,
                        agent_eligibility_decided_at: Time.current, agent_eligibility_decided_by: nil)
        RecordActivity.call(ticket: @ticket, action: "agent_eligibility_overridden",
                            actor_name: I18n.t("agents.supporter.activity_actor"),
                            data: { agent_eligibility: { from:, to: @ticket.agent_eligibility } })
      end
      Result.ok(@ticket)
    end

    private

    def decidable?
      @ticket.agent_eligibility_source_automatic? && !@ticket.agent_eligibility_advice_unknown? &&
        @ticket.project.supporter_enabled?
    end

    def needs_a_person?
      text = [ @ticket.title, @ticket.description, @ticket.technical_analysis ].join("\n")
      reserved = Agents::Supporters::ReservedTopics.new(organization: @ticket.project.organization, project: @ticket.project)
      reserved.match(text:).any? || Agents::Supporters::BypassGuard.match(text).any?
    end
  end
end
