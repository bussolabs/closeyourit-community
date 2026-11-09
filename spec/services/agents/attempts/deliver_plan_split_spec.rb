# frozen_string_literal: true

require "rails_helper"

# CYRA-1152 — an epic's plan may propose its child tickets. The proposal is saved with the plan, and a
# proposal that cannot stand is rejected at delivery: no plan, no ticket, and the phase goes back to
# the planner.
RSpec.describe Agents::Attempts::Deliver, "with a split proposal" do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let!(:repository) { create(:github_repository, project:) }
  let(:ticket) { create(:ticket, :epic, organization:, project:, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:profile) { Agents::PhaseProfile.for("planner") }
  let(:host_service_account) do
    Accounts::Service::Create.call(organization:, name: "Host SA", project_ids: [ project.id ]).value
  end
  let(:host) do
    create(:agent_host, organization:, service_account: host_service_account, last_heartbeat_at: Time.current,
                        repositories: [ project.key ], runtimes: [ { "name" => profile.runtime, "present" => true } ])
  end
  let(:attempt) do
    create(:agent_attempt, organization:, workflow:, host:, service_account: host_service_account,
                           skill_key: profile.skill_key, external_run_id: "run-split", phase: "planner",
                           runtime: profile.runtime)
  end
  let(:result) do
    JSON.parse(Rails.root.join("spec/fixtures/agents/planner_split.json").read).merge("code" => ticket.code)
  end

  before do
    workflow.update!(triaged_at: Time.current, ticket_snapshot_digest: "snapshot")
    create(:agent_lease, organization:, ticket:, host:, run_id: "run-split", execution_phase: "planner",
                         profile_digest: profile.digest, expires_at: 5.minutes.from_now)
  end

  def deliver(delivered = result)
    described_class.call(organization:, host:, attempt:,
                         payload: { runtime: profile.runtime, reviewer_runtime: attempt.reviewer,
                                    result: delivered, review: review_for("planner") })
  end

  def children(delivered = result) = delivered.dig("plan", "children")

  it "saves the proposal with the epic's plan and creates no ticket yet" do
    expect { expect(deliver).to be_ok }.not_to change(Ticketing::Ticket, :count)

    plan = workflow.plans.sole
    expect(plan.split.ordered.map(&:id)).to eq(%w[CH-1 CH-2 CH-3])
    expect(plan.technical_analysis).to include("Figli proposti", "Modificare le preferenze dal profilo")
    expect(workflow.reload.planned_at).to be_present
  end

  it "rejects a proposal over the cap: no plan, no ticket, and the plan goes back to the planner" do
    over = result.deep_dup
    over["plan"]["children"] = (1..(Agents::PlanSplit::MAX_CHILDREN + 1)).map do |index|
      children.first.merge("id" => "CH-#{index}", "title" => "Parte #{index}")
    end

    expect { expect(deliver(over)).to be_err }.not_to change(Ticketing::Ticket, :count)
    expect(workflow.plans).to be_empty
    expect(attempt.reload).to be_status_review_failed
    expect(workflow.reload.ready_execution_phase).to eq("planner")
  end

  it "still checks the rest of the plan against the vendored contract" do
    result["plan"]["unknown"] = "not in the contract"

    expect(deliver).to be_err
    expect(workflow.plans).to be_empty
  end

  it "rejects children that wait for each other" do
    children.first["dependencies"] = [ "CH-2" ]
    children.second["dependencies"] = [ "CH-1" ]

    expect { expect(deliver).to be_err }.not_to change(Ticketing::Ticket, :count)
    expect(workflow.plans).to be_empty
    expect(attempt.reload).to be_status_review_failed
  end

  it "rejects a prerequisite that names no proposed child" do
    children.first["dependencies"] = [ "CH-9" ]

    expect(deliver).to be_err
    expect(workflow.plans).to be_empty
  end

  it "rejects a split on a ticket that is not an epic: only an epic splits" do
    ticket.update!(kind: :story)

    expect(deliver).to be_err
    expect(workflow.plans).to be_empty
    expect(attempt.reload).to be_status_review_failed
  end

  it "leaves a plan without children as it was, on any ticket" do
    ticket.update!(kind: :story)
    result["plan"].delete("children")

    expect(deliver).to be_ok
    expect(workflow.plans.sole).not_to be_split
  end
end
