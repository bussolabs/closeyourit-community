# frozen_string_literal: true

require "rails_helper"

# CYAU-235 — the machine asks for the next round its supporter should answer, then sends the answers.
RSpec.describe "Api::V1::AgentHost::SupporterRounds", type: :request do
  let(:organization) { create(:organization) }
  let(:service_account) do
    create(:account, :service).tap { |a| create(:membership, account: a, organization:, role: :member) }
  end
  let(:host) { create(:agent_host, organization:, service_account:) }
  let(:plain) { "cyi_ah_plain_supporter_value" }
  let(:headers) { { "Authorization" => "Bearer #{plain}" } }
  let(:project) { create(:project, organization:, supporter_enabled: true) }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }

  before { create(:agent_host_token, host:, token_digest: Digest::SHA256.hexdigest(plain)) }

  it "answers 204 when there is nothing to answer" do
    get "/api/v1/agent_host/supporter_round", headers: headers
    expect(response).to have_http_status(:no_content)
  end

  it "serves a round and records the answers the server accepts" do
    round = create(:agent_clarification, workflow: ticket.agent_workflow, questions: [ "Which one?" ])

    get "/api/v1/agent_host/supporter_round", headers: headers
    item = response.parsed_body["data"]
    expect(item["round_id"]).to eq(round.id)

    question = item["questions"].first
    post "/api/v1/agent_host/supporter_rounds/#{round.id}/answer", headers: headers, as: :json, params: {
      digest: item["digest"],
      answers: [ { question_id: question["id"], text: "The first one", risk_score: 2, confidence: "high",
                   source_status: "written", sources: [ "README.md" ], rationale: "r", reasons_against: "a",
                   assumptions: "s", undo: "u" } ]
    }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body["data"]["outcome"]).to eq("answered")
    expect(round.reload.answered_at).to be_present
  end

  it "refuses an uncertified host" do
    host.update!(certified_at: nil)
    get "/api/v1/agent_host/supporter_round", headers: headers
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body["error"]["code"]).to eq("R403-SUPPORTER-002")
  end

  it "refuses a request without a host token" do
    get "/api/v1/agent_host/supporter_round"
    expect(response).to have_http_status(:unauthorized)
  end
end
