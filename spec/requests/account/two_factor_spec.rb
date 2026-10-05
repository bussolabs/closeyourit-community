# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Account::TwoFactor", type: :request do
  let(:account) { create(:account, email: "ada@example.com", password: "Secret123!") }

  # Login che completa il secondo fattore quando l'account ha già il 2FA attivo.
  def sign_in(who = account)
    post login_path, params: { email: who.email, password: "Secret123!" }
    complete_two_factor(who) if who.otp_enabled?
  end

  describe "GET /account/2fa" do
    it "richiede il login" do
      get account_two_factor_path
      expect(response).to redirect_to(login_path)
    end

    it "mostra lo stato non attivo di default" do
      sign_in
      get account_two_factor_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="two-factor-status-off"')
    end

    it "mostra lo stato attivo per un account con 2FA" do
      on = create(:account, :with_otp, email: "on@example.com", password: "Secret123!")
      sign_in(on)
      get account_two_factor_path
      expect(response.body).to include('data-test="two-factor-status-on"')
    end

    it "usa il layout account: topbar con menu utente e Home, non la sidebar member" do
      sign_in
      get account_two_factor_path
      expect(response.body).to include('data-test="account-user-menu"')
      expect(response.body).to include('data-test="account-nav-home"')
      expect(response.body).not_to include('data-test="member-nav-home"')
    end

    it "offre un ritorno all'app quando il 2FA è attivo (non solo la disattivazione)" do
      on = create(:account, :with_otp, email: "on2@example.com", password: "Secret123!")
      sign_in(on)
      get account_two_factor_path
      expect(response.body).to include('data-test="two-factor-back"')
    end

    it "mostra la corona Valhalla al god senza organizzazione (uscita god-safe)" do
      god = create(:account, :with_otp, god: true, email: "godtf@example.com", password: "Secret123!")
      sign_in(god)
      get account_two_factor_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="account-nav-valhalla"')
    end
  end

  describe "GET /account/2fa/setup" do
    it "provisiona il seme e mostra il QR + la chiave manuale" do
      sign_in
      get setup_account_two_factor_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="two-factor-qr"')
      expect(response.body).to include('data-test="two-factor-secret"')
      expect(account.reload.otp_secret).to be_present
    end

    it "reindirizza allo stato se il 2FA è già attivo" do
      on = create(:account, :with_otp, email: "on@example.com", password: "Secret123!")
      sign_in(on)
      get setup_account_two_factor_path
      expect(response).to redirect_to(account_two_factor_path)
    end
  end

  describe "POST /account/2fa/enable (FIX-A: richiede anche la password)" do
    it "con password e codice validi attiva il 2FA e mostra i codici di recupero una volta" do
      sign_in
      get setup_account_two_factor_path # provisiona il seme
      code = ROTP::TOTP.new(account.reload.otp_secret).now

      post enable_account_two_factor_path, params: { code: code, password: "Secret123!" }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="two-factor-recovery-codes"')
      expect(account.reload).to be_otp_enabled
      expect(account.otp_recovery_codes.count).to eq(Accounts::Constants::OTP_RECOVERY_CODES)
    end

    it "offers the recovery codes as a text file built in the browser, with every code in it" do
      sign_in
      get setup_account_two_factor_path
      code = ROTP::TOTP.new(account.reload.otp_secret).now

      post enable_account_two_factor_path, params: { code: code, password: "Secret123!" }

      link = Nokogiri::HTML(response.body).at_css('a[data-test="two-factor-recovery-download"]')
      expect(link["download"]).to eq("closeyourit-recovery-codes.txt")
      expect(link["href"]).to start_with("data:text/plain;charset=utf-8,")
      file = CGI.unescape(link["href"].delete_prefix("data:text/plain;charset=utf-8,"))
      codes = Nokogiri::HTML(response.body).css('[data-test="two-factor-recovery-codes"] li').map { |li| li.text.strip }
      expect(codes.size).to eq(Accounts::Constants::OTP_RECOVERY_CODES)
      expect(file.lines.map(&:strip)).to include(*codes)
      expect(file).to include(account.email)
    end

    it "con codice errato (password giusta) ri-mostra il setup 422 e NON attiva" do
      sign_in
      get setup_account_two_factor_path
      post enable_account_two_factor_path, params: { code: "000000", password: "Secret123!" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(account.reload).not_to be_otp_enabled
    end

    it "SENZA password NON attiva anche con codice valido (422)" do
      sign_in
      get setup_account_two_factor_path
      code = ROTP::TOTP.new(account.reload.otp_secret).now
      post enable_account_two_factor_path, params: { code: code }
      expect(response).to have_http_status(:unprocessable_content)
      expect(account.reload).not_to be_otp_enabled
    end

    it "con password errata NON attiva anche con codice valido (422)" do
      sign_in
      get setup_account_two_factor_path
      code = ROTP::TOTP.new(account.reload.otp_secret).now
      post enable_account_two_factor_path, params: { code: code, password: "Sbagliata9!" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(account.reload).not_to be_otp_enabled
    end
  end

  describe "DELETE /account/2fa (FIX-3: richiede riprova d'identità)" do
    it "con la password corrente disattiva il 2FA" do
      on = create(:account, :with_otp, email: "off@example.com", password: "Secret123!")
      sign_in(on)
      delete account_two_factor_path, params: { password: "Secret123!" }
      expect(response).to redirect_to(account_two_factor_path)
      expect(on.reload).not_to be_otp_enabled
    end

    it "con un codice TOTP valido disattiva il 2FA" do
      on = create(:account, :with_otp, email: "off2@example.com", password: "Secret123!")
      sign_in(on) # il login consuma il codice della finestra corrente (anti-replay FIX-8)
      # una finestra TOTP dopo, un codice FRESCO disattiva (il codice del login non sarebbe riusabile).
      travel_to(90.seconds.from_now) do
        delete account_two_factor_path, params: { code: current_totp(on) }
      end
      expect(response).to redirect_to(account_two_factor_path)
      expect(on.reload).not_to be_otp_enabled
    end

    it "SENZA riprova d'identità NON disattiva e ri-mostra la pagina con errore (422)" do
      on = create(:account, :with_otp, email: "off3@example.com", password: "Secret123!")
      sign_in(on)
      delete account_two_factor_path
      expect(response).to have_http_status(:unprocessable_content)
      expect(on.reload).to be_otp_enabled
    end

    it "con password errata NON disattiva (422)" do
      on = create(:account, :with_otp, email: "off4@example.com", password: "Secret123!")
      sign_in(on)
      delete account_two_factor_path, params: { password: "Sbagliata9!" }
      expect(response).to have_http_status(:unprocessable_content)
      expect(on.reload).to be_otp_enabled
    end

    it "con un codice di recupero valido disattiva il 2FA (FIX-C: alternativa alla password)" do
      on = create(:account, email: "off5@example.com", password: "Secret123!")
      codes = on.enable_otp!
      sign_in(on)
      delete account_two_factor_path, params: { code: codes.first }
      expect(response).to redirect_to(account_two_factor_path)
      expect(on.reload).not_to be_otp_enabled
    end

    it "la pagina di disattivazione espone sia il campo password sia il campo codice (FIX-C)" do
      on = create(:account, :with_otp, email: "off6@example.com", password: "Secret123!")
      sign_in(on)
      get account_two_factor_path
      expect(response.body).to include('data-test="two-factor-disable-password"')
      expect(response.body).to include('data-test="two-factor-disable-code"')
    end
  end

  # FIX-2: durante un'impersonation Current.account è la VITTIMA. L'enrollment 2FA deve agire SEMPRE sul
  # true_account (il god), mai sulla vittima, altrimenti il god ne manipolerebbe il secondo fattore.
  describe "durante un'impersonation l'enrollment agisce sul true_account (god), non sulla vittima" do
    let(:god) { create(:account, :with_otp, god: true, email: "god@example.com", password: "Secret123!") }
    let(:victim) { create(:account, email: "victim@example.com") }

    before do
      post login_path, params: { email: god.email, password: "Secret123!" }
      complete_two_factor(god)
      start_impersonation_as(god, account_id: victim.id) # CYRA-719: l'avvio passa dal secondo fattore
    end

    it "setup guarda lo stato del god (già attivo → redirect) e NON provisiona la vittima" do
      get setup_account_two_factor_path
      expect(response).to redirect_to(account_two_factor_path)
      expect(victim.reload.otp_secret).to be_nil
    end

    it "destroy con la password del god disattiva il 2FA del GOD, non tocca la vittima" do
      delete account_two_factor_path, params: { password: "Secret123!" }
      expect(god.reload).not_to be_otp_enabled
      expect(victim.reload.otp_enabled_at).to be_nil
    end
  end
end
