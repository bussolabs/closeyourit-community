# frozen_string_literal: true

require "rails_helper"

# CYAU-300 — a code conflict with main gets one resolution attempt before it waits for a person: the
# autopilot goes back to the queue marked for resolution, Codex takes it and Claude reviews it. If the
# resolver stops too, the work blocks as before. Nothing reaches main without a person's approval.
RSpec.describe Agents::Attempts::Deliver, "a code conflict with main" do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let!(:repository) { create(:github_repository, project:) }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:account) { create(:account) }
  let!(:membership) { create(:membership, account:, organization:, role: :owner) }

  before do
    organization.update_column(:cto_id, account.id)
    workflow.update!(ticket_snapshot_digest: "snapshot", triage_started_at: 3.hours.ago, triaged_at: 3.hours.ago,
                     planned_at: 2.hours.ago, approved_at: 1.hour.ago, autopilot_started_at: 1.minute.ago)
  end

  def deliver(result)
    Agents::Lease.where(ticket:).delete_all
    profile = Agents::PhaseProfile.for("autopilot")
    sa = Accounts::Service::Create.call(organization:, name: "Host SA #{SecureRandom.hex(3)}", project_ids: [ project.id ]).value
    host = create(:agent_host, organization:, service_account: sa, last_heartbeat_at: Time.current,
                               repositories: [ project.key ], runtimes: [ { "name" => profile.runtime, "present" => true } ])
    run_id = "run-#{SecureRandom.hex(3)}"
    attempt = create(:agent_attempt, organization:, workflow:, host:, service_account: sa, skill_key: profile.skill_key,
                                     external_run_id: run_id, phase: "autopilot", runtime: profile.runtime)
    create(:agent_lease, organization:, ticket:, host:, run_id:, execution_phase: "autopilot",
                         profile_digest: profile.digest, expires_at: 5.minutes.from_now)
    reviewer = profile.runtime == "claude" ? "codex" : "claude"
    described_class.call(
      organization:, host:, attempt:,
      payload: { runtime: profile.runtime, reviewer_runtime: reviewer, result: result.merge(code: ticket.code),
                 review: review_for("autopilot", summary: "Rapporto onesto e leggibile."), observed: observed_head }
    )
  end

  def conflict
    { contract_version: 2, state: "blocked", security_findings: [],
      failure: { category: "merge_conflict", summary: "app/models/ticket.rb conflicts with main", retryable: false,
                 human_action: "Resolve the conflict." } }
  end

  it "sends the work back to the queue for one resolution, without blocking it" do
    expect(deliver(conflict)).to be_ok

    expect(workflow.reload).to have_attributes(blocked_at: nil, autopilot_started_at: nil)
    expect(workflow.conflict_resolution_requested_at).to be_present
    expect(workflow.ready_execution_phase).to eq("autopilot")
  end

  it "blocks for a person when the resolution stops on a conflict too" do
    workflow.update!(conflict_resolution_requested_at: 10.minutes.ago)

    deliver(conflict)

    expect(workflow.reload).to have_attributes(blocked_phase: "autopilot", blocked_kind: "agent_blocked")
    expect(workflow.blocked_reason).to include("app/models/ticket.rb conflicts with main")
  end

  it "still blocks on any other reason" do
    deliver(conflict.deep_merge(failure: { category: "tooling", summary: "pnpm cannot run" }))

    expect(workflow.reload).to have_attributes(blocked_phase: "autopilot", conflict_resolution_requested_at: nil)
  end

  it "clears the request once the resolved work is delivered, so a later conflict gets its own try" do
    workflow.update!(conflict_resolution_requested_at: 10.minutes.ago)
    congela_vincolo!(workflow)

    outcome = deliver(state: "delivered", security_findings: [], gate: { passed: true }, review: { verdict: "approved" }, cycles: 1,
            delivery: { prUrl: "https://github.com/#{repository.full_name}/pull/7", cyiStatus: "in_review", autoMerged: false })

    expect(outcome).to be_ok, -> { outcome.error.inspect }
    expect(workflow.reload.conflict_resolution_requested_at).to be_nil
  end
end
