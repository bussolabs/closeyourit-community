# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Auth::Sessions", type: :request do
  let!(:account) { create(:account, email: "ada@example.com", password: "Secret123!") }

  describe "GET /login" do
    it "risponde 200" do
      get login_path
      expect(response).to have_http_status(:ok)
    end

    it "il titolo della scheda porta anche il nome del prodotto, come nelle altre pagine" do
      get login_path
      expect(Nokogiri::HTML(response.body).title).to eq("#{I18n.t('auth.sessions.title')} · CloseYourIt")
    end

    it "non mostra il select dev di prefill fuori da development" do
      get login_path
      expect(response.body).not_to include('data-test="dev-persona"')
    end

    it "email e password hanno gli autocomplete corretti (password manager)" do
      get login_path
      doc = Nokogiri::HTML(response.body)
      expect(doc.at_css('input[data-test="login-email"]')["autocomplete"]).to eq("username")
      expect(doc.at_css('input[data-test="login-password"]')["autocomplete"]).to eq("current-password")
    end
  end

  describe "POST /login" do
    it "con credenziali valide autentica e reindirizza alla home" do
      post login_path, params: { email: "ada@example.com", password: "Secret123!" }
      expect(response).to redirect_to(root_path)
      follow_redirect!
      expect(response).to have_http_status(:ok)
    end

    it "crea una sessione" do
      expect {
        post login_path, params: { email: "ada@example.com", password: "Secret123!" }
      }.to change(Accounts::Session, :count).by(1)
    end

    it "normalizza l'email (case-insensitive)" do
      post login_path, params: { email: "ADA@example.com", password: "Secret123!" }
      expect(response).to redirect_to(root_path)
    end

    it "con password errata ritorna 422" do
      post login_path, params: { email: "ada@example.com", password: "sbagliata" }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "con email inesistente ritorna 422" do
      post login_path, params: { email: "nessuno@example.com", password: "Secret123!" }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "rifiuta un service account anche con credenziali valide (CLI-only, nessuna sessione)" do
      create(:account, :service, email: "bot@example.com", password: "Secret123!")
      expect {
        post login_path, params: { email: "bot@example.com", password: "Secret123!" }
      }.not_to change(Accounts::Session, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "memorizza la pagina richiesta da anonimo e ci torna dopo il login" do
      # La root da guest è la landing pubblica (dual root): come pagina protetta di riferimento
      # si usa l'area account, org-independent.
      get account_cli_tokens_path
      expect(response).to redirect_to(login_path)
      post login_path, params: { email: "ada@example.com", password: "Secret123!" }
      expect(response).to redirect_to(account_cli_tokens_url)
    end
  end

  describe "DELETE /logout" do
    it "termina la sessione e reindirizza al login" do
      post login_path, params: { email: "ada@example.com", password: "Secret123!" }
      expect { delete logout_path }.to change(Accounts::Session, :count).by(-1)
      expect(response).to redirect_to(login_path)
    end
  end

  describe "scadenza e idle-timeout della sessione (CYRA-170)" do
    # account_cli_tokens_path = pagina protetta org-independent (come nel test del return-to).
    before { post login_path, params: { email: "ada@example.com", password: "Secret123!" } }

    it "posa una scadenza assoluta sulla sessione (non ~20 anni come .permanent)" do
      session = Accounts::Session.order(:created_at).last
      expect(session.expires_at).to be_within(1.minute).of(Accounts::Constants::SESSION_ABSOLUTE_TTL.from_now)
      expect(session.last_active_at).to be_within(1.minute).of(Time.current)
    end

    it "il cookie di sessione scade entro la finestra assoluta, non è permanente" do
      cookie = Array(response.headers["Set-Cookie"]).join("\n").lines.find { |c| c.include?("session_id=") }
      expires = cookie[/expires=([^;]+)/i, 1]
      expect(Time.zone.parse(expires)).to be_within(1.day).of(Accounts::Constants::SESSION_ABSOLUTE_TTL.from_now)
    end

    it "una sessione scaduta rimbalza al login e viene distrutta lato server" do
      Accounts::Session.order(:created_at).last.update_column(:expires_at, 1.hour.ago)
      expect { get account_cli_tokens_path }.to change(Accounts::Session, :count).by(-1)
      expect(response).to redirect_to(login_path)
    end

    it "una sessione idle (inattiva oltre la soglia) rimbalza al login e viene distrutta" do
      Accounts::Session.order(:created_at).last
        .update_column(:last_active_at, (Accounts::Constants::SESSION_IDLE_TIMEOUT + 1.hour).ago)
      expect { get account_cli_tokens_path }.to change(Accounts::Session, :count).by(-1)
      expect(response).to redirect_to(login_path)
    end

    it "aggiorna last_active_at su una sessione viva quando l'ultima attività è più vecchia del throttle" do
      session = Accounts::Session.order(:created_at).last
      session.update_column(:last_active_at, (Accounts::Constants::SESSION_LAST_ACTIVE_THROTTLE + 5.minutes).ago)
      get account_cli_tokens_path
      expect(session.reload.last_active_at).to be_within(1.minute).of(Time.current)
    end

    it "NON riscrive last_active_at entro la finestra di throttle" do
      session = Accounts::Session.order(:created_at).last
      recent = 30.seconds.ago
      session.update_column(:last_active_at, recent)
      get account_cli_tokens_path
      expect(session.reload.last_active_at).to be_within(1.second).of(recent)
    end
  end
end
