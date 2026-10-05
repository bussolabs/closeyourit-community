# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::ServerTokens", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  it "senza bearer → 401" do
    get "/cli/v1/server_tokens"
    expect(response).to have_http_status(:unauthorized)
  end

  context "owner" do
    before { create(:membership, account:, organization:, role: :owner) }

    it "index → 200 con i token dell'org (mai il digest)" do
      token = create(:server_enrollment_token, organization:, name: "fleet")
      other = create(:server_enrollment_token)

      get "/cli/v1/server_tokens", headers: headers

      data = response.parsed_body["data"]
      ids = data.map { |x| x["id"] }
      expect(ids).to include(token.id)
      expect(ids).not_to include(other.id)
      row = data.find { |x| x["id"] == token.id }
      expect(row["token_prefix"]).to be_present
      expect(row).not_to have_key("token_digest")
      expect(row).not_to have_key("secret")
    end

    it "create → 201 col segreto reveal-once cyi_s_, persistito solo il digest" do
      expect { post "/cli/v1/server_tokens", params: { confirm: "1", name: "fleet" }, headers: headers }
        .to change(Servers::EnrollmentToken, :count).by(1)

      expect(response).to have_http_status(:created)
      data = response.parsed_body["data"]
      expect(data["name"]).to eq("fleet")
      expect(data["secret"]).to start_with(Servers::Constants::TOKEN_PREFIX)
      token = Servers::EnrollmentToken.last
      expect(token.token_digest).to eq(Digest::SHA256.hexdigest(data["secret"]))

      # il segreto non ricompare nelle letture successive
      get "/cli/v1/server_tokens", headers: headers
      expect(response.body).not_to include(data["secret"])
    end

    it "create con nome duplicato → 422 R422-SERVER-003" do
      create(:server_enrollment_token, organization:, name: "fleet")

      post "/cli/v1/server_tokens", params: { confirm: "1", name: "fleet" }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-SERVER-003")
    end

    it "destroy revoca (soft) il token" do
      token = create(:server_enrollment_token, organization:)

      delete "/cli/v1/server_tokens/#{token.id}", params: { confirm: "1" }, headers: headers

      expect(response).to have_http_status(:no_content)
      expect(token.reload.revoked?).to be(true)
    end

    it "destroy di un token di un'altra org → 404 (anti-BOLA)" do
      other = create(:server_enrollment_token)

      delete "/cli/v1/server_tokens/#{other.id}", params: { confirm: "1" }, headers: headers

      expect(response).to have_http_status(:not_found)
      expect(other.reload.revoked?).to be(false)
    end
  end

  context "member senza servers.manage" do
    before { create(:membership, account:, organization:, role: :member) }

    it "index → 403 e create → 403" do
      get "/cli/v1/server_tokens", headers: headers
      expect(response).to have_http_status(:forbidden)

      expect { post "/cli/v1/server_tokens", params: { name: "x" }, headers: headers }
        .not_to change(Servers::EnrollmentToken, :count)
      expect(response).to have_http_status(:forbidden)
    end
  end
end
