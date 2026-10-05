# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::Invitations", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  it "senza bearer → 401" do
    post "/cli/v1/invitations", params: { email: "x@example.com" }
    expect(response).to have_http_status(:unauthorized)
  end

  context "owner (members.invite)" do
    before { create(:membership, account:, organization:, role: :owner) }

    # La CLI stampava sempre "Email delivery is not wired in production", frase fissa che non guardava
    # niente: deve poter dire la verità, e la verità la sa solo il server.
    it "dichiara se le mail vengono consegnate" do
      post "/cli/v1/invitations", params: { email: "wired@example.com" }, headers: headers
      expect(response.parsed_body["data"]["email_delivery"]).to be(true)

      allow(ActionMailer::Base).to receive(:perform_deliveries).and_return(false)
      post "/cli/v1/invitations", params: { email: "unwired@example.com" }, headers: headers
      expect(response.parsed_body["data"]["email_delivery"]).to be(false)
    end

    it "create → 201 con invito customer (default) e accept_url" do
      expect do
        post "/cli/v1/invitations", headers: headers, params: { email: "client@example.com" }
      end.to change(Connections::Invitation, :count).by(1)

      expect(response).to have_http_status(:created)
      data = response.parsed_body["data"]
      expect(data["email"]).to eq("client@example.com")
      expect(data["role"]).to eq("customer")
      expect(data["accept_url"]).to include("/invitations/")
    end

    it "create con ruolo esplicito" do
      post "/cli/v1/invitations", headers: headers, params: { email: "a@example.com", role: "member" }
      expect(response.parsed_body["data"]["role"]).to eq("member")
    end

    it "email già membro → 422 R422-INVITE-004" do
      post "/cli/v1/invitations", headers: headers, params: { email: account.email }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-INVITE-004")
    end

    it "ruolo non ammesso → 422 R422-INVITE-003" do
      post "/cli/v1/invitations", headers: headers, params: { email: "b@example.com", role: "owner" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body["error"]["code"]).to eq("R422-INVITE-003")
    end

    it "index → 200 con gli inviti dell'org" do
      create(:invitation, organization:, email: "pending@example.com")

      get "/cli/v1/invitations", headers: headers

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["data"].map { |i| i["email"] }).to include("pending@example.com")
    end

    it "destroy → 204" do
      inv = create(:invitation, organization:)
      delete "/cli/v1/invitations/#{inv.id}", headers: headers
      expect(response).to have_http_status(:no_content)
      expect(Connections::Invitation).not_to exist(inv.id)
    end

    it "destroy di un invito di un'altra org → 404 (anti-BOLA)" do
      other = create(:invitation)
      delete "/cli/v1/invitations/#{other.id}", headers: headers
      expect(response).to have_http_status(:not_found)
    end
  end

  context "membro senza members.invite" do
    before { create(:membership, account:, organization:, role: :member) }

    it "create → 403 R403-CLIAUTH-002" do
      post "/cli/v1/invitations", headers: headers, params: { email: "x@example.com" }
      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["error"]["code"]).to eq("R403-CLIAUTH-002")
    end
  end
end
