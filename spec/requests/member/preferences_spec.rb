# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Preferences", type: :request do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }
  let!(:membership) { create(:membership, account: account, organization: org, role: :member) }

  def sign_in(acct)
    post login_path, params: { email: acct.email, password: "Secret123!" }
  end

  describe "PATCH update" do
    it "salva la preferenza projects_view dell'utente e reindirizza" do
      sign_in(account)
      patch member_preferences_path, params: { projects_view: "table" }
      expect(response).to redirect_to(member_projects_path)
      expect(account.reload.projects_view).to eq("table")
    end

    it "accetta 'cards'" do
      sign_in(account)
      patch member_preferences_path, params: { projects_view: "cards" }
      expect(account.reload.projects_view).to eq("cards")
    end

    it "ignora un valore non ammesso (preferenza invariata)" do
      account.update!(projects_view: "cards")
      sign_in(account)
      patch member_preferences_path, params: { projects_view: "kanban" }
      expect(response).to redirect_to(member_projects_path)
      expect(account.reload.projects_view).to eq("cards")
    end

    it "anche il ruolo customer può impostare la propria preferenza" do
      customer = create(:account)
      create(:membership, account: customer, organization: org, role: :customer)
      sign_in(customer)
      patch member_preferences_path, params: { projects_view: "table" }
      expect(customer.reload.projects_view).to eq("table")
    end

    it "non autenticato → redirect al login" do
      patch member_preferences_path, params: { projects_view: "table" }
      expect(response).to redirect_to(login_path)
    end
  end

  describe "GET show" do
    it "non autenticato → redirect al login" do
      get member_preferences_path
      expect(response).to redirect_to(login_path)
    end

    it "autenticato → 200" do
      sign_in(account)
      create(:platform, organization: org)
      get member_preferences_path
      expect(response).to have_http_status(:ok)
    end

    # FIX-D: la strip delle impostazioni espone l'accesso all'enrollment 2FA (area account).
    it "espone la tab Sicurezza verso l'enrollment 2FA" do
      sign_in(account)
      get member_preferences_path
      expect(response.body).to include('data-test="settings-tab-security"')
      expect(response.body).to include(account_two_factor_path)
    end
  end

  describe "PATCH update — platform_codes (globali)" do
    before { sign_in(account) }

    it "salva i codici puliti (downcase, no blank, unici) e reindirizza alle preferenze" do
      patch member_preferences_path, params: { platform_codes: [ "", "iOS", "web", "web" ] }
      expect(account.reload.platform_codes).to eq([ "ios", "web" ])
      expect(response).to redirect_to(member_preferences_path)
    end

    it "azzera la selezione quando arriva solo il blank" do
      account.update!(platform_codes: [ "ios" ])
      patch member_preferences_path, params: { platform_codes: [ "" ] }
      expect(account.reload.platform_codes).to eq([])
    end
  end

  describe "PATCH update — locale (lingua interfaccia)" do
    before { sign_in(account) }

    it "salva la preferenza locale dell'utente e reindirizza" do
      patch member_preferences_path, params: { locale: "it" }
      expect(response).to redirect_to(member_projects_path)
      expect(account.reload.locale).to eq("it")
    end

    it "accetta 'en'" do
      patch member_preferences_path, params: { locale: "en" }
      expect(account.reload.locale).to eq("en")
    end

    it "ignora una lingua non ammessa (preferenza invariata)" do
      account.update!(locale: "en")
      patch member_preferences_path, params: { locale: "fr" }
      expect(account.reload.locale).to eq("en")
    end
  end

  describe "GET show — lingua dell'interfaccia (around_action)" do
    it "rende la UI in inglese quando l'account non ha preferenza" do
      sign_in(account)
      get member_preferences_path
      expect(response.body).to include("Language")
      expect(response.body).not_to include(">Lingua<")
    end

    it "rende la UI in italiano quando l'account ha locale 'it'" do
      account.update!(locale: "it")
      sign_in(account)
      get member_preferences_path
      expect(response.body).to include(">Lingua<")
      expect(response.body).not_to include(">Language<")
    end
  end
end
