require "rails_helper"

RSpec.describe "Coworkers worker", type: :request do
  let(:organization) { create(:organization) }
  let(:account) { create(:account) }
  let!(:membership) { create(:membership, account: account, organization: organization, role: :owner) }
  let(:puck) { Coworkers::Puck.create!(organization: organization, account: account, name: "Researcher", instructions: "Cite sources") }
  let!(:run) { puck.runs.create!(kind: "chat", input: "Hello", context: { request: "Hello" }) }
  let(:headers) { { "Authorization" => "Bearer #{'test-only-worker-' * 4}" } }

  before do
    allow(Coworkers).to receive(:enabled?).and_return(true)
    allow(Coworkers).to receive(:remote?).and_return(true)
    allow(Coworkers).to receive(:worker_token_digest).and_return(Digest::SHA256.hexdigest("test-only-worker-" * 4))
    allow(Coworkers).to receive(:worker_organization_id).and_return(organization.id)
    allow(Coworkers).to receive(:worker_account_ids).and_return([ account.id ])
  end

  def claim
    post "/api/v1/coworkers/claims", headers: headers, as: :json
    response.parsed_body.is_a?(Hash) ? response.parsed_body["data"] : nil
  end

  def report(lease, sequence:, events: [])
    post "/api/v1/coworkers/runs/#{run.id}/events", headers: headers,
      params: { lease_id: lease, sequence: sequence, events: events }, as: :json
  end

  it "rejects missing authentication without revealing work" do
    post "/api/v1/coworkers/claims", as: :json
    expect(response).to have_http_status(:unauthorized)
    expect(run.reload.status).to eq("queued")
  end

  it "claims once and returns only the authorized snapshot" do
    first = claim
    expect(first).to include("id" => run.id, "kind" => "chat", "prompt" => run.context.to_json)
    expect(first.fetch("lease_id")).to be_present
    expect(claim).to be_nil
    expect(run.reload.status).to eq("running")
  end

  it "cannot claim another account or organization" do
    allow(Coworkers).to receive(:worker_account_ids).and_return([ SecureRandom.uuid ])
    expect(claim).to be_nil
    allow(Coworkers).to receive(:worker_account_ids).and_return([ account.id ])
    allow(Coworkers).to receive(:worker_organization_id).and_return(SecureRandom.uuid)
    expect(claim).to be_nil
  end

  it "rejects a forged lease and an out of order batch" do
    lease = claim.fetch("lease_id")
    report(SecureRandom.uuid, sequence: 1)
    expect(response).to have_http_status(:conflict)
    report(lease, sequence: 2)
    expect(response).to have_http_status(:conflict)
    expect(run.reload.worker_sequence).to eq(0)
  end

  it "saves streaming output once when a batch is retried" do
    lease = claim.fetch("lease_id")
    # Two HTTP requests repeat authentication; this is not a query loop within one request.
    allow_n_plus_one { 2.times { report(lease, sequence: 1, events: [ { type: "delta", text: "Hello" } ]) } }
    expect(response).to have_http_status(:ok)
    expect(run.reload.output).to eq("Hello")
  end

  it "persists a proposal only on a successful finish without starting a task" do
    lease = claim.fetch("lease_id")
    proposal = { objective: "Find museums", activities: "Read sources", limits: "Public web only" }
    report(lease, sequence: 1, events: [ { type: "proposal", proposal: proposal } ])
    expect(run.reload.proposed_task).to eq({})
    expect {
      report(lease, sequence: 2, events: [ { type: "result", success: true, output: "Ready" }, { type: "end", code: 0 } ])
    }.not_to have_enqueued_job
    expect(run.reload).to have_attributes(status: "completed", output: "Ready", proposed_task: proposal.stringify_keys)
    expect(puck.runs.where(kind: "task")).to be_empty
  end

  it "rejects task success without a successful research tool" do
    run.update!(kind: "task")
    lease = claim.fetch("lease_id")
    report(lease, sequence: 1, events: [ { type: "result", success: true, output: "No evidence" }, { type: "end", code: 0 } ])
    expect(run.reload.status).to eq("failed")
  end

  it "acknowledges a repeated final batch without reopening the run" do
    lease = claim.fetch("lease_id")
    events = [ { type: "result", success: true, output: "Done" }, { type: "end", code: 0 } ]
    # A lost acknowledgement repeats the whole HTTP request.
    allow_n_plus_one { 2.times { report(lease, sequence: 1, events: events) } }
    expect(response).to have_http_status(:ok)
    expect(run.reload.status).to eq("completed")
  end

  it "stops on the next heartbeat and rejects late output" do
    lease = claim.fetch("lease_id")
    run.update!(stop_requested: true)
    report(lease, sequence: 1, events: [ { type: "delta", text: "Late" } ])
    expect(response.parsed_body.dig("data", "stop")).to be(true)
    expect(run.reload).to have_attributes(status: "stopped", output: "")
  end

  it "expires a disconnected worker and never replays its task" do
    lease = claim.fetch("lease_id")
    travel 46.seconds do
      Coworkers::ReapJob.perform_now
      report(lease, sequence: 1)
      expect(response).to have_http_status(:conflict)
      expect(run.reload.status).to eq("interrupted")
      expect(claim).to be_nil
    end
  end

  it "rolls back an invalid batch without keeping its partial changes" do
    lease = claim.fetch("lease_id")
    report(lease, sequence: 1, events: [ { type: "delta", text: "Partial" }, { type: "unknown" } ])
    expect(response).to have_http_status(:unprocessable_content)
    expect(run.reload).to have_attributes(output: "", worker_sequence: 0)
  end

  it "closes the worker API when remote execution is disabled" do
    allow(Coworkers).to receive(:remote?).and_return(false)
    claim
    expect(response).to have_http_status(:not_found)
  end
  it "refuses a third simultaneous claim" do
    2.times do |index|
      other = Coworkers::Puck.create!(account: account, organization: organization, name: "Worker #{index}", instructions: "Cite sources")
      other.runs.create!(kind: "chat", input: "Queued #{index}")
    end
    # Separate claims each repeat the same admission queries.
    allow_n_plus_one do
      expect(claim).to be_present
      expect(claim).to be_present
      expect(claim).to be_nil
    end
  end

  it "rejects reports after the owner loses membership" do
    lease = claim.fetch("lease_id")
    membership.destroy!
    report(lease, sequence: 1)
    expect(response).to have_http_status(:conflict)
    travel 46.seconds do
      Coworkers::ReapJob.perform_now
      expect(run.reload.status).to eq("interrupted")
    end
  end

  it "rejects a reused sequence carrying different content" do
    lease = claim.fetch("lease_id")
    report(lease, sequence: 1, events: [ { type: "delta", text: "First" } ])
    report(lease, sequence: 1, events: [ { type: "delta", text: "Changed" } ])
    expect(response).to have_http_status(:conflict)
    expect(run.reload.output).to eq("First")
  end

  it "completes research only after matching tool evidence" do
    run.update!(kind: "task")
    lease = claim.fetch("lease_id")
    report(lease, sequence: 1, events: [
      { type: "tool", id: "browser-1", name: "mcp__coworkers__browser_read" },
      { type: "tool_result", id: "browser-1", success: true },
      { type: "result", success: true, output: "Source-backed result" },
      { type: "end", code: 0 }
    ])
    expect(run.reload.status).to eq("completed")
  end

  it "rejects successful tool results that have no matching call" do
    lease = claim.fetch("lease_id")
    report(lease, sequence: 1, events: [ { type: "tool_result", id: "unknown", success: true } ])
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "rejects a suspended organization" do
    organization.update!(suspended_at: Time.current)
    claim
    expect(response).to have_http_status(:forbidden)
  end
  it "checks readiness without claiming or exposing a conversation" do
    post "/api/v1/coworkers/readiness", headers: headers, as: :json
    expect(response.parsed_body.fetch("data")).to eq("protocol" => "coworkers-worker/v1")
    expect(run.reload.status).to eq("queued")
  end
end
