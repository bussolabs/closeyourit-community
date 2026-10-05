# frozen_string_literal: true

# Helper condivisi per gli spec che passano dal secondo fattore (2FA TOTP, CYRA-170).
# Usati dagli spec che entrano in Valhalla/impersonation (dove il god DEVE avere il 2FA) e dal gate login.
module TwoFactorHelpers
  # Stesso seme del factory trait :with_otp: noto → l'helper genera un TOTP valido.
  TEST_OTP_SECRET = "JBSWY3DPEHPK3PXP"

  # Attiva il 2FA su un account con un seme noto (senza passare dall'enrollment).
  def enable_two_factor!(account)
    account.update!(otp_secret: TEST_OTP_SECRET, otp_enabled_at: Time.current)
  end

  # Codice TOTP valido corrente per un account con 2FA (secret noto).
  def current_totp(account)
    ROTP::TOTP.new(account.otp_secret).now
  end
end

# Helper per i request spec (secondo fattore via POST).
module TwoFactorRequestHelpers
  include TwoFactorHelpers

  # Completa il secondo fattore dopo un POST /login che ha messo l'account in pending 2FA.
  def complete_two_factor(account)
    post two_factor_challenge_path, params: { code: current_totp(account) }
  end

  # Login completo di un god pronto per Valhalla (CYRA-170): attiva il 2FA al volo se manca e completa
  # il secondo fattore. Così gli spec Valhalla restano quasi invariati: cambia solo la riga di login.
  def sign_in_god(account)
    enable_two_factor!(account) unless account.otp_enabled?
    post login_path, params: { email: account.email, password: "Secret123!" }
    complete_two_factor(account)
  end

  # Avvia un'impersonation passando dalla re-auth col secondo fattore (CYRA-719). Il codice speso al
  # login non vale una seconda volta (anti-replay di verify_otp): la prova si sposta nella finestra
  # TOTP successiva e genera lì il codice, esattamente come deve fare una persona reale.
  def start_impersonation_as(god, params)
    travel_to(1.minute.from_now) do
      post impersonation_path, params: params.merge(code: current_totp(god))
    end
  end
end

# Helper per i system spec (secondo fattore via UI Capybara). Il god deve avere il 2FA per raggiungere
# Valhalla/impersonation (FIX-5/FIX-10): i loro sign_in_as lo attivano al volo e chiamano questo dopo il
# submit del login. Per un account senza 2FA è un no-op (la challenge non compare).
module TwoFactorSystemHelpers
  include TwoFactorHelpers

  def complete_two_factor_ui(account)
    return unless account.reload.otp_enabled?

    fill_test "two-factor-code", with: current_totp(account)
    click_on_test "two-factor-submit"
  end

  # Conferma dell'impersonation col secondo fattore (CYRA-719): il codice speso al login non vale una
  # seconda volta (anti-replay), quindi la conferma avviene nella finestra TOTP successiva.
  def confirm_impersonation_ui(account)
    travel_to(1.minute.from_now) do
      fill_test "impersonation-code", with: current_totp(account)
      click_on_test "impersonation-submit"
    end
  end
end

RSpec.configure do |config|
  config.include TwoFactorRequestHelpers, type: :request
  config.include TwoFactorSystemHelpers, type: :system
end
