# frozen_string_literal: true

module Auth
  # Secondo fattore del login (CYRA-170): raggiunto dopo che Auth::SessionsController#create ha superato
  # la password di un account con 2FA attivo. Verifica un codice TOTP oppure un codice di recupero
  # monouso; solo allora crea la sessione. Il pending è un token firmato legato alla password (FIX-4) nella
  # rack session, che scade da sé dopo Accounts::Constants::OTP_PENDING_TTL; un lockout (FIX-B) lo annulla.
  class TwoFactorSessionsController < BaseController
    before_action :require_pending_challenge

    def new
    end

    def create
      if verify_second_factor
        account = @pending_account
        consume_two_factor_challenge # single-use: marca la challenge consumata (anti-replay del cookie)
        start_new_session_for(account)
        # FIX-5: la sessione appena creata ha superato il secondo fattore → marcala verificata (gate god).
        Current.session.update_column(:two_factor_verified_at, Time.current)
        redirect_to after_authentication_url, notice: t("auth.sessions.signed_in")
      else
        handle_failed_second_factor
      end
    end

    private

    # FIX-B/FIX-J (CYRA-170): lockout legato al PENDING (non all'IP). Il throttle rack-attack two_factor/ip
    # è per-IP → una botnet lo aggira; qui contiamo i tentativi falliti SERVER-SIDE (cache keyed sul token)
    # e, raggiunta la soglia, CONSUMIAMO la challenge (single-use: nemmeno rigiocando il vecchio cookie col
    # token ancora valido si riparte da zero). Il brute-force DISTRIBUITO residuo (rifare login+pending da
    # molti IP) resta mitigato dal throttle login/ip: rischio accettato, niente lockout per-account (DoS).
    def handle_failed_second_factor
      register_failed_two_factor_attempt
      if two_factor_attempts_exhausted?
        consume_two_factor_challenge
        redirect_to login_path, alert: t("auth.two_factor.locked_out")
      else
        flash.now[:alert] = t("auth.two_factor.invalid_code")
        render :new, status: :unprocessable_content
      end
    end

    # Nessun pending (arrivo diretto) o pending scaduto → si ricomincia dal login. pending_two_factor_account
    # ripulisce da sé la sessione quando è scaduto.
    def require_pending_challenge
      @pending_account = pending_two_factor_account
      redirect_to login_path, alert: t("auth.two_factor.expired") if @pending_account.nil?
    end

    # Accetta indifferentemente un codice TOTP o un codice di recupero (quest'ultimo viene consumato).
    def verify_second_factor
      code = params[:code].to_s
      @pending_account.verify_otp(code) || @pending_account.verify_recovery_code(code)
    end
  end
end
