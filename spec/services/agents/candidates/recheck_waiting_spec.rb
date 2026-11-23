# frozen_string_literal: true

require "rails_helper"

# CYRA-1346, CYRA-1347 — a delivery left in front of a person is looked at again: in conflict it goes back
# to the agent, otherwise the automatic yes is asked again.
RSpec.describe Agents::Candidates::RecheckWaiting do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let!(:repository) { create(:github_repository, project:, full_name: "bussolabs/closeyourit-rails") }
  let!(:in_review) { create(:ticket_status, :in_review, organization:, position: 2) }
  let!(:in_progress) { create(:ticket_status, :in_progress, organization:, position: 1) }
  let(:ticket) { create(:ticket, organization:, project:, status: in_review, with_agent_workflow: true) }
  let(:workflow) do
    ticket.agent_workflow.tap do |flow|
      flow.update!(autopilot_started_at: 2.days.ago, autopilot_completed_at: 2.days.ago, candidate_verified_at: 2.days.ago)
    end
  end
  let(:attempt) do
    create(:agent_attempt, workflow:, organization:, phase: "autopilot", status: :approved,
                           review_status: :accepted, reviewer_runtime: "codex",
                           review: { "status" => "accepted", "summary" => "fine" })
  end
  let(:candidate) do
    create(:agent_delivery_candidate, :verified_none_configured, workflow:, attempt:, repository:, organization:,
                                                                 repository_full_name: "bussolabs/closeyourit-rails", number: 7)
  end
  let(:memory_store) { ActiveSupport::Cache::MemoryStore.new }

  def client(mergeable:)
    instance_double(Github::Client).tap do |fake|
      allow(fake).to receive(:pull_request_state).and_return({ head_sha: candidate.head_sha, mergeable: })
      allow(fake).to receive(:repository_file).and_return(nil)
    end
  end

  before do
    allow(Rails).to receive(:cache).and_return(memory_store)
    service_account = create(:account, :service).tap { |account| create(:project_membership, account:, project:) }
    create(:agent_host, organization:, service_account:, repositories: [ project.key ],
                        runtimes: [ { "name" => "claude", "present" => true } ])
    workflow.update!(review_candidate_id: candidate.id)
  end

  it "sends a delivery that fell into conflict back to the agent for the resolution round" do
    described_class.call(client: client(mergeable: "CONFLICTING"))

    expect(workflow.reload).to have_attributes(autopilot_started_at: nil, autopilot_completed_at: nil, blocked_at: nil)
    expect(workflow.conflict_resolution_requested_at).to be_present
  end

  it "stops with the reason when the resolution round was already used" do
    workflow.update!(conflict_resolution_requested_at: 1.day.ago)

    described_class.call(client: client(mergeable: "CONFLICTING"))

    expect(workflow.reload.blocked_reason).to include("merge_conflict")
  end

  it "asks the automatic yes again for a delivery that merges" do
    described_class.call(client: client(mergeable: "MERGEABLE"))

    expect(workflow.reload.autopilot_approved_at).to be_present
  end

  it "leaves alone a delivery a person refused" do
    Ticketing::Event.create!(organization:, ticket:, action: "review_rejected", actor_name: "Ada", data: { "mode" => "hold" })

    described_class.call(client: client(mergeable: "MERGEABLE"))

    expect(workflow.reload.autopilot_approved_at).to be_nil
  end

  it "looks at each delivery once, then lets it rest" do
    fake = client(mergeable: "UNKNOWN")
    allow(Agents::Workflows::AutoApprove).to receive(:call).and_return(Result.ok(nil))

    2.times { described_class.call(client: fake) }

    expect(fake).to have_received(:pull_request_state).once
  end

  it "leaves the work where it was when GitHub does not answer" do
    fake = instance_double(Github::Client)
    allow(fake).to receive(:pull_request_state).and_raise(Github::Client::Error.new("down", code: "R502-GITHUB-001"))

    expect(described_class.call(client: fake).value).to eq(0)
    expect(workflow.reload).to have_attributes(autopilot_approved_at: nil, blocked_at: nil)
  end
end
