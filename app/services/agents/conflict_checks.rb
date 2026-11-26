# frozen_string_literal: true

module Agents
  # CYRA-1154 — when main moves, the delivered proposals still waiting for a person or for the staging
  # release are asked whether they still merge. One rule says which work is waiting, in SQL and in Ruby.
  module ConflictChecks
    # Delivered, verified, not blocked and not yet taken by the staging closer: the phases
    # `awaiting_autopilot_approval` and `closer_staging_queued`. Work the agent is doing is not here.
    def self.waiting_workflows
      Agents::Workflow.where(cancelled_at: nil, completed_at: nil, blocked_at: nil, closer_staging_started_at: nil)
                      .where.not(autopilot_completed_at: nil)
                      .where.not(candidate_verified_at: nil)
                      .where.not(review_candidate_id: nil)
    end

    # Twin of `waiting_workflows` for one row, read again under lock: same delivered proposal too.
    def self.waiting_on?(workflow, check)
      !workflow.terminal? && !workflow.blocked_at? && workflow.closer_staging_started_at.nil? &&
        workflow.autopilot_completed_at? && workflow.candidate_verified_at? &&
        workflow.review_candidate_id.present? && workflow.review_candidate_id == check.delivery_candidate_id
    end

    # Why this row must not move the work, or nil when it may. Read before asking GitHub and again under
    # lock before the send back: a retry can come minutes after the push, and by then the work, the person
    # or the repository may have moved. The repository rules are the push's own (Github::Webhooks::Base).
    def self.skip_reason(workflow, check)
      return "no_longer_waiting" unless waiting_on?(workflow, check)
      return "held_by_person" if Agents::Candidates::ConflictRework.held_by_person?(workflow)

      repository_skip_reason(check.delivery_candidate.repository, workflow)
    end

    def self.repository_skip_reason(repository, workflow)
      installation = repository&.installation
      return "repository_not_linked" if installation.nil? || repository.project.organization_id != workflow.organization.id
      return "sync_disabled" unless repository.sync_enabled?

      "organization_suspended" if installation.organization&.suspended?
    end
  end
end
