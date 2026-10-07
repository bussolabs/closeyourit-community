require "rails_helper"

RSpec.describe "Coworkers worker edge cases", type: :request do
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
    response.parsed_body["data"]
  end

  def report(lease, sequence:, events: [])
    post "/api/v1/coworkers/runs/#{run.id}/events", headers: headers,
      params: { lease_id: lease, sequence: sequence, events: events }, as: :json
  end

  def session(lease, op:, args:)
    post "/api/v1/coworkers/runs/#{run.id}/session", headers: headers,
      params: { lease_id: lease, op: op, args: args }, as: :json
  end

  describe "event batches" do
    it "rejects an oversized request body before reading it" do
      lease = claim.fetch("lease_id")
      report(lease, sequence: 1, events: [ { type: "delta", text: "x" * 262_145 } ])
      expect(response).to have_http_status(:unprocessable_content)
      expect(run.reload.output).to eq("")
    end

    it "rejects events that are not a list of objects" do
      lease = claim.fetch("lease_id")
      report(lease, sequence: 1, events: "delta")
      expect(response).to have_http_status(:unprocessable_content)
      expect(run.reload.worker_sequence).to eq(0)
    end

    it "accepts an empty heartbeat and extends the lease" do
      lease = claim.fetch("lease_id")
      report(lease, sequence: 1)
      expect(response.parsed_body["data"]).to eq("sequence" => 1, "stop" => false)
      expect(run.reload.worker_sequence).to eq(1)
    end

    it "refuses a repeated batch once the lease has expired" do
      lease = claim.fetch("lease_id")
      events = [ { type: "delta", text: "Hello" } ]
      report(lease, sequence: 1, events: events)
      travel 46.seconds do
        report(lease, sequence: 1, events: events)
        expect(response).to have_http_status(:conflict)
      end
      expect(run.reload.output).to eq("Hello")
    end
  end

  it "answers a tool call whose input is not an object with an empty input" do
    run.update!(scope: Coworkers::Scope.capture(account: account, organization: organization))
    lease = claim.fetch("lease_id")
    post "/api/v1/coworkers/runs/#{run.id}/tools", headers: headers,
      params: { lease_id: lease, call_id: "call-1", name: "list_projects", input: "everything" }, as: :json
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "result")).to be_a(Hash)
  end

  describe "browser session calls" do
    before { run.update!(kind: "task") }

    it "answers a session call of a claimed task" do
      lease = claim.fetch("lease_id")
      session(lease, op: "site_secret", args: { domain: "unknown.example" })
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "result")).to eq("error" => "unknown_site")
    end

    it "treats arguments that are not an object as empty" do
      lease = claim.fetch("lease_id")
      session(lease, op: "control", args: "noise")
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.dig("data", "result", "steps")).to eq([])
    end

    it "refuses a forged lease and an unknown operation" do
      lease = claim.fetch("lease_id")
      session(SecureRandom.uuid, op: "site_secret", args: {})
      expect(response).to have_http_status(:conflict)
      session(lease, op: "drop_database", args: {})
      expect(response).to have_http_status(:unprocessable_content)
    end
  end
end
