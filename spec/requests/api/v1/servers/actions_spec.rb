# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Api::V1::Servers::Actions", type: :request do
  let(:host) { create(:server_host) }
  let(:secret) { "cyi_h_test-secret" }
  let!(:token) do
    create(:server_host_token, host:, token_digest: Digest::SHA256.hexdigest(secret))
  end
  let(:headers) { { "Authorization" => "Bearer #{secret}", "CONTENT_TYPE" => "application/json" } }

  it "claim → risultato, autenticati e scoped all'host" do
    action = create(:server_action, host:, organization: host.organization)
    post "/api/v1/servers/action_claims", headers: headers
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.dig("data", "id")).to eq(action.id)

    put "/api/v1/servers/actions/#{action.id}", params: { status: "succeeded", exit_code: 0 }.to_json,
        headers: headers
    expect(response).to have_http_status(:ok)
    expect(action.reload).to be_status_succeeded
  end

  it "senza token host risponde 401" do
    post "/api/v1/servers/action_claims"
    expect(response).to have_http_status(:unauthorized)
  end

  it "non permette di completare l'azione di un altro host" do
    foreign = create(:server_action, status: :running)
    put "/api/v1/servers/actions/#{foreign.id}", params: { status: "succeeded" }.to_json, headers: headers
    expect(response).to have_http_status(:not_found)
  end
end
