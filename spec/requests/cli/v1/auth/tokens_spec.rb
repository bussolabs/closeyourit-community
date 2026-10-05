# frozen_string_literal: true

require "rails_helper"

# CYRA-643 — i propri token CLI dal terminale: elenco e revoca, senza passare dal browser. È la metà
# che mancava al "ho perso il portatile": la pagina web c'era, la riga di comando no.
RSpec.describe "Cli::V1 auth/tokens (i propri token)", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }

  before { create(:membership, account:, organization:) }

  let(:issued) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI corrente").value }
  let(:secret) { issued[:secret] }
  let(:current_token) { issued[:token] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  describe "autenticazione" do
    it "senza bearer → 401 R401-CLIAUTH-001" do
      get "/cli/v1/auth/tokens"
      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["error"]["code"]).to eq("R401-CLIAUTH-001")
    end
  end

  describe "GET /cli/v1/auth/tokens" do
    it "elenca i propri token e marca quello in uso" do
      altro = create(:api_token, account:, organization:, name: "Fisso ufficio")

      get "/cli/v1/auth/tokens", headers: headers

      expect(response).to have_http_status(:ok)
      righe = response.parsed_body["data"]
      expect(righe.map { |r| r["id"] }).to contain_exactly(current_token.id, altro.id)
      corrente = righe.find { |r| r["id"] == current_token.id }
      expect(corrente["current"]).to be(true)
      expect(righe.find { |r| r["id"] == altro.id }["current"]).to be(false)
    end

    it "attraversa le organizzazioni e dice a quale appartiene ogni token" do
      seconda = create(:organization, name: "Seconda Org")
      create(:membership, account:, organization: seconda)
      altrove = create(:api_token, account:, organization: seconda)

      get "/cli/v1/auth/tokens", headers: headers

      riga = response.parsed_body["data"].find { |r| r["id"] == altrove.id }
      expect(riga["organization"]["name"]).to eq("Seconda Org")
    end

    it "non elenca i token di un altro account" do
      altrui = create(:api_token)

      get "/cli/v1/auth/tokens", headers: headers

      expect(response.parsed_body["data"].map { |r| r["id"] }).not_to include(altrui.id)
    end

    it "non rivela mai il segreto né il suo digest" do
      get "/cli/v1/auth/tokens", headers: headers

      expect(response.body).not_to include(secret)
      expect(response.body).not_to include("token_digest")
    end

    it "elenca anche i token già revocati, con la data di revoca" do
      revocato = create(:api_token, :revoked, account:, organization:)

      get "/cli/v1/auth/tokens", headers: headers

      riga = response.parsed_body["data"].find { |r| r["id"] == revocato.id }
      expect(riga["revoked_at"]).to be_present
    end
  end

  describe "DELETE /cli/v1/auth/tokens/:id" do
    it "revoca un proprio token → 204" do
      token = create(:api_token, account:, organization:)

      delete "/cli/v1/auth/tokens/#{token.id}", headers: headers

      expect(response).to have_http_status(:no_content)
      expect(token.reload.revoked?).to be(true)
    end

    it "il token di un altro account → 404 (mai 403: non si conferma che esiste)" do
      altrui = create(:api_token)

      delete "/cli/v1/auth/tokens/#{altrui.id}", headers: headers

      expect(response).to have_http_status(:not_found)
      expect(altrui.reload.revoked?).to be(false)
    end

    it "id inesistente → 404" do
      delete "/cli/v1/auth/tokens/#{SecureRandom.uuid}", headers: headers
      expect(response).to have_http_status(:not_found)
    end

    it "revoca il token in uso senza far fallire la risposta" do
      delete "/cli/v1/auth/tokens/#{current_token.id}", headers: headers

      expect(response).to have_http_status(:no_content)
      expect(current_token.reload.revoked?).to be(true)
    end

    it "«current» revoca il token con cui si sta chiamando (logout che chiude davvero)" do
      delete "/cli/v1/auth/tokens/current", headers: headers

      expect(response).to have_http_status(:no_content)
      expect(current_token.reload.revoked?).to be(true)
    end

    it "dopo la revoca lo stesso segreto non entra più → 401" do
      delete "/cli/v1/auth/tokens/current", headers: headers

      get "/cli/v1/auth/tokens", headers: headers

      expect(response).to have_http_status(:unauthorized)
    end

    it "è idempotente: ri-revocare un token già revocato resta 204" do
      token = create(:api_token, :revoked, account:, organization:)
      original = token.revoked_at

      delete "/cli/v1/auth/tokens/#{token.id}", headers: headers

      expect(response).to have_http_status(:no_content)
      expect(token.reload.revoked_at).to be_within(1.second).of(original)
    end
  end
end
