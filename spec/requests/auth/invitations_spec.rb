# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Auth::Invitations", type: :request do
  let(:invitation) { create(:invitation, email: "new@example.com") }
  let(:token) { invitation.generate_token_for(:invitation) }

  describe "GET /invitations/:token/edit" do
    it "token valido → 200" do
      get edit_invitation_path(token)
      expect(response).to have_http_status(:ok)
    end

    # Con un account già esistente la password del modulo viene scartata da AcceptInvitation: chiederla
    # significa far scegliere una password che non varrà nulla, e poi rimandare al login.
    it "account già esistente → niente campo password, ma il contesto dell'invito resta" do
      create(:account, email: invitation.email)
      get edit_invitation_path(token)
      expect(response.body).not_to include('data-test="invite-password"')
      expect(response.body).to include('data-test="invite-existing"')
      expect(response.body).to include('data-test="invite-email"')
    end

    it "account nuovo → il modulo chiede nome e password" do
      get edit_invitation_path(token)
      expect(response.body).to include('data-test="invite-password"')
      expect(response.body).not_to include('data-test="invite-existing"')
    end

    it "token invalido → redirect al login" do
      get edit_invitation_path("spazzatura")
      expect(response).to redirect_to(login_path)
    end

    it "invito già accettato → redirect al login" do
      invitation.update!(accepted_at: Time.current)
      get edit_invitation_path(token)
      expect(response).to redirect_to(login_path)
    end
  end

  describe "PATCH /invitations/:token" do
    it "accetta l'invito, crea l'account e autentica" do
      patch invitation_path(token), params: { name: "Bob", password: "Secret123!", password_confirmation: "Secret123!" }
      expect(response).to redirect_to(root_path)
      expect(Accounts::Account.find_by(email: "new@example.com")).to be_present
      expect(invitation.reload).to be_accepted
    end

    it "password debole → 422" do
      patch invitation_path(token), params: { name: "Bob", password: "debole", password_confirmation: "debole" }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "email di un account già esistente → collega la membership e reindirizza al login, senza auto-login (CYRA-164)" do
      create(:account, email: "new@example.com")
      patch invitation_path(token), params: { name: "Bob", password: "Secret123!", password_confirmation: "Secret123!" }
      expect(response).to redirect_to(login_path) # NON root_path: nessun auto-login coi dati dell'invito
      expect(invitation.reload).to be_accepted
      expect(invitation.organization.accounts.exists?(email: "new@example.com")).to be(true)
    end

    it "token scaduto → redirect al login" do
      scaduto = invitation.generate_token_for(:invitation)
      travel_to(Connections::Constants::TTL_INVITATION.from_now + 1.second) do
        patch invitation_path(scaduto), params: { name: "Bob", password: "Secret123!", password_confirmation: "Secret123!" }
        expect(response).to redirect_to(login_path)
      end
    end
  end
end
