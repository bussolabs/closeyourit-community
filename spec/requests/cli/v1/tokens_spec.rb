# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Tokens (project ingest)", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:environment) { create(:environment, organization:).tap { |e| project.environments << e } }

  def token_for(acc)
    Accounts::ApiTokens::Issue.call(account: acc, organization:, name: "CLI").value[:secret]
  end

  context "owner (tokens.manage)" do
    before { create(:membership, account:, organization:, role: :owner) }
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "index → 200 con i token del progetto" do
      tok = create(:project_token, project:)
      get "/cli/v1/projects/#{project.id}/tokens", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].map { |t| t["id"] }).to include(tok.id)
    end

    it "create → 201 e rivela secret + dsn una volta" do
      environment # forza la dichiarazione dell'environment sul progetto
      post "/cli/v1/projects/#{project.id}/tokens", headers: headers,
                                                    params: { confirm: "1", name: "CI", environment_id: environment.id }

      expect(response).to have_http_status(:created)
      data = response.parsed_body["data"]
      expect(data["secret"]).to start_with("cyi_")
      expect(data["dsn"]).to be_present
      expect(data["dsn"]).to end_with("/#{project.id}")
      expect(data["sentry_dsn"]).to match(%r{\Ahttps://[0-9a-f]{32}@[^/]+/#{project.reload.sentry_project_id}\z})
      expect(data["token"]["token_prefix"]).to be_present
    end

    # CYRA-716 — la scadenza si legge e si imposta anche dal terminale.
    it "index → la scadenza è nel payload" do
      tok = create(:project_token, project:, expires_at: 30.days.from_now)
      get "/cli/v1/projects/#{project.id}/tokens", headers: headers

      riga = response.parsed_body["data"].find { |t| t["id"] == tok.id }
      expect(riga["expires_at"]).to be_present
    end

    it "create con expires_at → il token nasce a termine" do
      environment
      post "/cli/v1/projects/#{project.id}/tokens", headers: headers,
                                                    params: { confirm: "1", name: "CI", environment_id: environment.id,
                                                              expires_at: 30.days.from_now.iso8601 }

      expect(response).to have_http_status(:created)
      expect(response.parsed_body["data"]["token"]["expires_at"]).to be_present
    end

    it "create con expires_at nel passato → 422 e nessun token" do
      environment
      expect do
        post "/cli/v1/projects/#{project.id}/tokens", headers: headers,
                                                      params: { confirm: "1", name: "CI", environment_id: environment.id,
                                                                expires_at: 1.day.ago.iso8601 }
      end.not_to change(project.tokens, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-TOKEN-001")
    end

    it "rotate (PUT rotation) → nuovo secret e vecchio token revocato" do
      tok = create(:project_token, project:)
      put "/cli/v1/projects/#{project.id}/tokens/#{tok.id}/rotation", params: { confirm: "1" }, headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"]["secret"]).to start_with("cyi_")
      expect(response.parsed_body["data"]["dsn"]).to end_with("/#{project.id}")
      expect(response.parsed_body["data"]["sentry_dsn"]).to end_with("/#{project.reload.sentry_project_id}")
      expect(tok.reload.revoked?).to be(true)
    end

    it "destroy → 204 e revoca" do
      tok = create(:project_token, project:)
      delete "/cli/v1/projects/#{project.id}/tokens/#{tok.id}", params: { confirm: "1" }, headers: headers

      expect(response).to have_http_status(:no_content)
      expect(tok.reload.revoked?).to be(true)
    end

    it "create con Issue fallita → render_error col codice/status del Result" do
      allow(::Projects::Tokens::Issue).to receive(:call).and_return(
        Result.err(AppError.new("emissione fallita", code: "R422-TOKEN-001", status: :unprocessable_content))
      )
      post "/cli/v1/projects/#{project.id}/tokens", headers: headers, params: { confirm: "1", name: "CI" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-TOKEN-001")
    end

    it "rotate con Rotate fallita → render_error col codice/status del Result" do
      tok = create(:project_token, project:)
      allow(::Projects::Tokens::Rotate).to receive(:call).and_return(
        Result.err(AppError.new("rotazione fallita", code: "R422-TOKEN-002", status: :unprocessable_content))
      )
      put "/cli/v1/projects/#{project.id}/tokens/#{tok.id}/rotation", params: { confirm: "1" }, headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-TOKEN-002")
    end

    it "token di un'altra org → 404 (anti-BOLA)" do
      other = create(:project_token)
      get "/cli/v1/projects/#{other.project_id}/tokens", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  context "member che vede il progetto ma senza tokens.manage" do
    before do
      create(:membership, account:, organization:, role: :member)
      create(:project_membership, account:, project:)
    end
    let(:headers) { { "Authorization" => "Bearer #{token_for(account)}" } }

    it "index → 403" do
      get "/cli/v1/projects/#{project.id}/tokens", headers: headers
      expect(response).to have_http_status(:forbidden)
    end

    it "create → 403" do
      post "/cli/v1/projects/#{project.id}/tokens", headers: headers,
                                                    params: { name: "CI", environment_id: environment.id }
      expect(response).to have_http_status(:forbidden)
    end
  end
end
