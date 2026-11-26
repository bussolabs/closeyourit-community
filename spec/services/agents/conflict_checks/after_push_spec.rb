# frozen_string_literal: true

require "rails_helper"

# CYRA-1154 — from GitHub's push of main to what the agent reads: the delivered proposal that no longer
# merges goes back to work in the same round, without waiting for the staging release.
RSpec.describe "A change of main reaching a delivered proposal" do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let!(:repository) do
    create(:github_repository, project:, full_name: "bussolabs/closeyourit-rails", default_branch: "main")
  end
  let!(:in_review) { create(:ticket_status, :in_review, organization:) }
  let!(:working) { create(:ticket_status, :in_progress, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, status: in_review, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let!(:candidate) { delivered_waiting!(ticket:, repository:) }
  let(:client) { instance_double(Github::Client) }

  before do
    allow(client).to receive(:pull_request_state).and_return(merge_state("CONFLICTING"))
    allow(Github::Client).to receive(:new).and_return(client)
  end

  def push!(ref: "refs/heads/main")
    Github::Webhooks::Push.call(payload: {
      "ref" => ref, "after" => "e" * 40,
      "repository" => { "id" => repository.repo_id },
      "installation" => { "id" => repository.installation.installation_id },
      "commits" => [ { "message" => "Rename the login form" }, { "message" => "Move the header\n\nWhy it moved" } ]
    })
  end

  def notices = ticket.events.where(action: "pull_request_conflict")

  it "sends the conflicting proposal back in the same round, and the agent reads what landed" do
    perform_enqueued_jobs(only: Agents::ConflictCheckJob) { push! }

    expect(workflow.reload.ready_execution_phase).to eq("autopilot")
    expect(workflow.conflict_resolution_requested_at).to be_present
    expect(ticket.reload.status).to eq(working)

    finding = AgentTicketCandidateSerializer.new(ticket.reload).as_json.dig("workflow", :rework, :findings).sole
    expect(finding[:detail]).to include("- Rename the login form", "- Move the header", "can be incomplete")
  end

  it "sends the proposal back once when GitHub delivers the same push twice" do
    perform_enqueued_jobs(only: Agents::ConflictCheckJob) { 2.times { push! } }

    expect(notices.count).to eq(1)
    expect(client).to have_received(:pull_request_state).once
  end

  it "asks GitHub nothing for a push to a working branch" do
    perform_enqueued_jobs(only: Agents::ConflictCheckJob) { push!(ref: "refs/heads/ticket/CYRA-990") }

    expect(client).not_to have_received(:pull_request_state)
    expect(workflow.reload.phase).to eq("awaiting_autopilot_approval")
  end
end
