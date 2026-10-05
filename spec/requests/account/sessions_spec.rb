# frozen_string_literal: true

require "rails_helper"

# CYRA-643 — le sessioni del browser non avevano una pagina: chi perdeva un dispositivo poteva solo
# cambiare la password e buttare giù tutto. Qui si vedono una per una e si chiudono una per una.
RSpec.describe "Account::Sessions (accessi attivi)", type: :request do
  let(:account) { create(:account) }

  def sign_in_as(acc)
    post login_path, params: { email: acc.email, password: "Secret123!" }
  end

  def current_session_id
    Accounts::Session.where(account:).order(created_at: :desc).first.id
  end

  it "senza login → redirect a /login" do
    get account_sessions_path
    expect(response).to redirect_to(login_path)
  end

  describe "GET /account/sessions" do
    it "elenca le proprie sessioni attive e marca quella in uso" do
      sign_in_as(account)
      corrente = current_session_id
      altra = create(:session, account:, user_agent: "Mozilla/5.0 (Windows NT 10.0) Firefox/128.0")

      get account_sessions_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("account-sessions-row-#{corrente}")
      expect(response.body).to include("account-sessions-row-#{altra.id}")
      expect(response.body).to include("account-sessions-current-#{corrente}")
      expect(response.body).not_to include("account-sessions-current-#{altra.id}")
    end

    # CYRA-924 — every column but the actions sorts (C9).
    it "sorts by address both ways and offers every column" do
      sign_in_as(account)
      low = create(:session, account:, ip_address: "10.0.0.1")
      high = create(:session, account:, ip_address: "99.0.0.1")

      get account_sessions_path, params: { sort: "address" }
      expect(response.body.index("account-sessions-row-#{low.id}")).to be < response.body.index("account-sessions-row-#{high.id}")
      get account_sessions_path, params: { sort: "-address" }
      expect(response.body.index("account-sessions-row-#{high.id}")).to be < response.body.index("account-sessions-row-#{low.id}")
      %w[device address last_active signed_in].each { |key| expect(response.body).to include("sort=#{key}").or include("sort=-#{key}") }
    end

    it "non elenca le sessioni di un altro account" do
      sign_in_as(account)
      altrui = create(:session, account: create(:account))

      get account_sessions_path

      expect(response.body).not_to include("account-sessions-row-#{altrui.id}")
    end

    it "non elenca le sessioni scadute o inattive (sono già morte lato server)" do
      sign_in_as(account)
      scaduta = create(:session, :expired, account:)
      inattiva = create(:session, :idle, account:)

      get account_sessions_path

      expect(response.body).not_to include("account-sessions-row-#{scaduta.id}")
      expect(response.body).not_to include("account-sessions-row-#{inattiva.id}")
    end

    it "mostra il dispositivo con parole leggibili, non la stringa grezza del browser" do
      sign_in_as(account)
      create(:session, account:, user_agent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")

      get account_sessions_path

      expect(response.body).to include("Chrome")
      expect(response.body).to include("macOS")
      expect(response.body).not_to include("AppleWebKit/537.36")
    end

    it "con una sola sessione non propone di chiudere le altre" do
      sign_in_as(account)

      get account_sessions_path

      expect(response.body).not_to include('data-test="account-sessions-revoke-others"')
    end

    it "con più sessioni propone di chiudere tutte le altre" do
      sign_in_as(account)
      create(:session, account:)

      get account_sessions_path

      expect(response.body).to include('data-test="account-sessions-revoke-others"')
    end
  end

  describe "DELETE /account/sessions/:id" do
    it "chiude una propria sessione: quel dispositivo non entra più" do
      sign_in_as(account)
      altra = create(:session, account:)

      delete account_session_path(altra)

      expect(response).to redirect_to(account_sessions_path)
      expect(Accounts::Session.exists?(altra.id)).to be(false)
    end

    it "lascia in piedi le altre sessioni e quella in uso" do
      sign_in_as(account)
      corrente = current_session_id
      da_chiudere = create(:session, account:)
      da_tenere = create(:session, account:)

      delete account_session_path(da_chiudere)

      expect(Accounts::Session.exists?(da_tenere.id)).to be(true)
      expect(Accounts::Session.exists?(corrente)).to be(true)
    end

    it "la sessione di un altro account → 404, e resta viva" do
      sign_in_as(account)
      altrui = create(:session, account: create(:account))

      delete account_session_path(altrui)

      expect(response).to have_http_status(:not_found)
      expect(Accounts::Session.exists?(altrui.id)).to be(true)
    end

    it "la sessione in uso non si chiude da qui: si esce dal menu" do
      sign_in_as(account)
      corrente = current_session_id

      delete account_session_path(corrente)

      expect(response).to redirect_to(account_sessions_path)
      expect(Accounts::Session.exists?(corrente)).to be(true)
    end
  end

  describe "DELETE /account/sessions/others" do
    it "chiude tutte le altre e tiene solo quella in uso" do
      sign_in_as(account)
      corrente = current_session_id
      create_list(:session, 3, account:)

      delete others_account_sessions_path

      expect(response).to redirect_to(account_sessions_path)
      expect(account.sessions.pluck(:id)).to contain_exactly(corrente)
    end

    it "non tocca le sessioni di un altro account" do
      sign_in_as(account)
      altrui = create(:session, account: create(:account))

      delete others_account_sessions_path

      expect(Accounts::Session.exists?(altrui.id)).to be(true)
    end

    it "chi resta dentro continua a navigare senza rifare l'accesso" do
      sign_in_as(account)
      create(:session, account:)

      delete others_account_sessions_path
      get account_sessions_path

      expect(response).to have_http_status(:ok)
    end
  end

  # CYRA-924 — signing a device out asks in a dialog that names it, never in the browser box (F16, P2).
  describe "sign-out confirmation (dialog)" do
    it "opens a dialog for one device and one for every other device" do
      sign_in_as(account)
      other = create(:session, account:, user_agent: "Mozilla/5.0 (Windows NT 10.0) Firefox/128.0")

      get account_sessions_path

      html = Nokogiri::HTML(response.body)
      dialog = html.at_css("dialog[data-test='account-sessions-revoke-dialog-#{other.id}']")
      expect(dialog.text).to include(I18n.t("account.sessions.revoke_dialog.title", device: other.device_label))
      expect(dialog.at_css("form")["action"]).to eq(account_session_path(other))
      expect(html.at_css("[data-test='account-sessions-revoke-#{other.id}']")["data-action"]).to eq("ui--dialog#open")
      others = html.at_css("dialog[data-test='account-sessions-revoke-others-dialog']")
      expect(others.at_css("form")["action"]).to eq(others_account_sessions_path)
      expect(html.at_css("[data-test='account-sessions-revoke-others']")["data-action"]).to eq("ui--dialog#open")
      expect(response.body).not_to include("data-turbo-confirm")
    end
  end
end
