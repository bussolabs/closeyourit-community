# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::AgentHost::CouncilSlices", type: :request do
  let(:organization) { create(:organization) }
  let(:service_account) do
    create(:account, :service).tap { |a| create(:membership, account: a, organization:, role: :owner) }
  end
  let(:host) { create(:agent_host, organization:, service_account:) }
  let(:plain) { "cyi_ah_plain_council_value" }
  let(:headers) { { "Authorization" => "Bearer #{plain}" } }

  before do
    create(:agent_host_token, host:, token_digest: Digest::SHA256.hexdigest(plain))
    create(:agent_automator_setting, organization:, council_mode: "dry_run")
    allow(Ticketing::FindSimilarTickets).to receive(:call).and_return(Result.ok([]))
    allow(Ideas::FindSimilarIdeas).to receive(:call).and_return(Result.ok([]))
  end

  it "answers 204 when no project is active" do
    get "/api/v1/agent_host/council_slice", headers: headers
    expect(response).to have_http_status(:no_content)
  end

  it "serves a slice and takes its result" do
    create(:project, organization:, council_enabled: true)

    get "/api/v1/agent_host/council_slice", headers: headers
    run_id = response.parsed_body.dig("data", "run_id")
    expect(run_id).to be_present

    post "/api/v1/agent_host/council_slices/#{run_id}/result", headers: headers, as: :json, params: {
      proposals: [ { ref: "claude-1", proposer: "claude", title: "Cache it", problem: "Slow", kind: "code", risk: "low" } ],
      critiques: [ { ref: "claude-1", critic: "codex", vote: "approve", risk: "low", reason: "ok" } ]
    }
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "outcomes")).to eq("dry_ticket" => 1)
  end

  it "refuses an uncertified host" do
    host.update!(certified_at: nil)
    get "/api/v1/agent_host/council_slice", headers: headers
    expect(response).to have_http_status(:forbidden)
  end
end
