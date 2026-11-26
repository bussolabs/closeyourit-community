# frozen_string_literal: true

# CYRA-1154 — a delivery waiting on a person: the agent delivered, the system verified the proposal
# and pointed the workflow at it. `approved:` moves it one step on, approved but not yet released.
module AgentConflictChecks
  def delivered_waiting!(ticket:, repository:, number: 7, approved: false)
    workflow = ticket.agent_workflow
    workflow.update!(triage_requested_at: 4.hours.ago, triage_started_at: 4.hours.ago, triaged_at: 3.hours.ago,
                     planned_at: 3.hours.ago, approved_at: 2.hours.ago, autopilot_started_at: 2.hours.ago,
                     autopilot_completed_at: 1.hour.ago, ticket_snapshot_digest: "snapshot")
    candidate = FactoryBot.create(:agent_delivery_candidate, :verified_passing,
                                  workflow:, repository:, organization: repository.project.organization,
                                  repository_full_name: repository.full_name, number:)
    workflow.update!(candidate_verified_at: 1.hour.ago, review_candidate_id: candidate.id)
    workflow.update!(autopilot_approved_at: 30.minutes.ago) if approved
    candidate
  end

  # The shape of `Github::Client#pull_request_state`, with the merge answer under test.
  def merge_state(mergeable, state: "OPEN")
    { head_sha: "d" * 40, base_ref: "main", state:, draft: false, mergeable:, merge_commit: nil, checks: [],
      checks_known: true, base_repository: "bussolabs/closeyourit-rails", base_default_branch: "main",
      head_committed_at: 1.hour.ago.iso8601 }
  end
end

RSpec.configure { |config| config.include AgentConflictChecks }
