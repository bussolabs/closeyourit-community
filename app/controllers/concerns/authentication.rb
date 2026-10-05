# frozen_string_literal: true

# Autenticazione session-based (pattern Rails 8) adattata a Accounts::Account/Session.
# La sessione è referenziata da un cookie firmato permanente `session_id`.
module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :require_authentication
    helper_method :authenticated?
  end

  class_methods do
    def allow_unauthenticated_access(**options)
      skip_before_action :require_authentication, **options
    end
  end

  private

  # Helper per le view (pattern auth Rails 8): l'account corrente è autenticato? Delega a resume_session.
  def authenticated?
    resume_session
  end

  def require_authentication
    resume_session || request_authentication
  end

  def resume_session
    Current.session ||= find_session_by_cookie
    if Current.session
      Current.true_account = Current.session.account
      Current.account = Current.session.impersonated_account || Current.session.account
    end
    Current.session
  end

  def find_session_by_cookie
    return if cookies.signed[:session_id].blank?

    session = Accounts::Session.find_by(id: cookies.signed[:session_id])
    return if session.nil?

    # Scadenza assoluta o idle-timeout (CYRA-170): la sessione muore lato server anche se il cookie
    # firmato è ancora integro. Distruggo la riga + pulisco il cookie e tratto la richiesta come anonima.
    if session.expired? || session.idle?
      session.destroy
      cookies.delete(:session_id)
      return
    end

    touch_session_activity(session)
    session
  end

  # Aggiorna last_active_at al massimo una volta ogni SESSION_LAST_ACTIVE_THROTTLE (idle-timeout ≠ una
  # UPDATE per richiesta). update_column: nessuna validazione/callback, non tocca updated_at. resume_session
  # memoizza Current.session con ||= → questo scatta una sola volta per richiesta.
  def touch_session_activity(session)
    floor = Accounts::Constants::SESSION_LAST_ACTIVE_THROTTLE.ago
    return if session.last_active_at.present? && session.last_active_at > floor

    session.update_column(:last_active_at, Time.current)
  end

  def request_authentication
    session[:return_to_after_authenticating] = request.url
    # Qui la lingua non è ancora quella del login (Auth::BaseController): l'avviso la anticipa.
    login_locale = Localizable.browser_locale(request) || I18n.default_locale
    redirect_to login_path, alert: t("auth.sessions.required", locale: login_locale)
  end

  def after_authentication_url
    session.delete(:return_to_after_authenticating) || root_url
  end

  def start_new_session_for(account)
    # Remembered filters and period belong to whoever used the browser before this login.
    session.delete(RememberableFilters::SESSION_KEY)
    session.delete(TimeRangeable::SESSION_KEY)
    now = Time.current
    expires_at = now + Accounts::Constants::SESSION_ABSOLUTE_TTL
    account.sessions.create!(
      user_agent: request.user_agent, ip_address: request.remote_ip,
      expires_at: expires_at, last_active_at: now
    ).tap do |session|
      Current.session = session
      Current.true_account = account
      Current.account = account
      # CYRA-170: cookie a scadenza esplicita (= scadenza assoluta della sessione), non più `.permanent`
      # (~20 anni). secure esplicito: in prod force_ssl lo imporrebbe comunque, ma dichiararlo rende il
      # cookie Secure-only per intento (difesa in profondità, non affidata solo al middleware).
      cookies.signed[:session_id] = {
        value: session.id, httponly: true, same_site: :lax,
        secure: Rails.env.production?, expires: expires_at
      }
    end
  end

  # --- Gate 2FA al login (CYRA-170) ---
  # Superata la password ma con 2FA attivo, NON si crea la sessione: si mette in sospeso l'account e si
  # chiede il secondo fattore. Il pending vive nella rack session (server-side) come TOKEN firmato legato
  # alla versione della password (FIX-4): scade da sé (OTP_PENDING_TTL) e si invalida se la password
  # cambia. Vedi Auth::SessionsController#create e Auth::TwoFactorSessionsController.
  def start_two_factor_challenge(account)
    session[:pending_2fa_token] = account.generate_token_for(:two_factor_login)
  end

  # Account in attesa del secondo fattore, o nil se: non c'è pending, è scaduto o la password è cambiata
  # (token → find_by_token_for), la challenge è già stata CONSUMATA (successo/lockout precedente), o i
  # tentativi sono esauriti. Consumato/esaurito vivono SERVER-SIDE (cache), non nel cookie: un attaccante
  # che rigioca il vecchio CookieStore col token ancora valido resta bloccato perché lo stato è nostro.
  def pending_two_factor_account
    token = session[:pending_2fa_token]
    return if token.blank?
    return if two_factor_challenge_consumed?(token)
    return if two_factor_attempts_exhausted?(token)

    Accounts::Account.find_by_token_for(:two_factor_login, token)
  end

  # Rimuove il pending dalla rack session (lato client legittimo). NON tocca lo stato server-side
  # (contatore, flag consumato): deve sopravvivere ai replay del cookie e scade da sé col TTL.
  def clear_two_factor_challenge
    session.delete(:pending_2fa_token)
  end

  # Chiude DEFINITIVAMENTE la challenge (successo o lockout): la marca CONSUMATA server-side, così il token
  # — ancora crittograficamente valido nel cookie fino a scadenza — non è più riutilizzabile (single-use).
  # Senza, al lockout il replay del cookie ripartirebbe da zero aggirando OTP_MAX_ATTEMPTS (FIX-J).
  def consume_two_factor_challenge
    token = session[:pending_2fa_token]
    if token.present?
      Rails.cache.write(two_factor_consumed_key(token), true, expires_in: Accounts::Constants::OTP_PENDING_TTL)
    end
    clear_two_factor_challenge
  end

  # Contatore tentativi + flag "consumato" del secondo fattore, SERVER-SIDE (FIX-H/FIX-J): NON possono
  # vivere nella rack session (CookieStore, rigiocabile azzerata). Stanno in Rails.cache (Solid Cache),
  # chiave = digest del token pending + TTL = finestra pending → sopravvivono ai replay del cookie e
  # scadono da sé. Il digest evita di mettere il token in chiaro nella chiave.
  def register_failed_two_factor_attempt
    token = session[:pending_2fa_token]
    return if token.blank?

    key = two_factor_fails_key(token)
    # Incremento ATOMICO cache-native (FIX-K): un read-modify-write perderebbe conteggi con richieste
    # concorrenti, lasciando aggirare OTP_MAX_ATTEMPTS. increment inizializza a 1 su chiave assente
    # (MemoryStore/Solid Cache); il fallback write copre eventuali store che ritornassero nil.
    Rails.cache.increment(key, 1, expires_in: Accounts::Constants::OTP_PENDING_TTL) ||
      Rails.cache.write(key, 1, expires_in: Accounts::Constants::OTP_PENDING_TTL)
  end

  def two_factor_failure_count(token = session[:pending_2fa_token])
    token.present? ? Rails.cache.read(two_factor_fails_key(token)).to_i : 0
  end

  def two_factor_attempts_exhausted?(token = session[:pending_2fa_token])
    two_factor_failure_count(token) >= Accounts::Constants::OTP_MAX_ATTEMPTS
  end

  def two_factor_challenge_consumed?(token = session[:pending_2fa_token])
    token.present? && Rails.cache.read(two_factor_consumed_key(token)).present?
  end

  def two_factor_fails_key(token)
    "two_factor_fails:#{Digest::SHA256.hexdigest(token)}"
  end

  def two_factor_consumed_key(token)
    "two_factor_consumed:#{Digest::SHA256.hexdigest(token)}"
  end

  # Gate 2FA del god (CYRA-170 FIX-5/FIX-10): il secondo fattore è obbligatorio per le capacità god
  # (pannello Valhalla e AVVIO impersonation). Il 2FA è del true_account (identità god reale, non
  # l'eventuale account impersonato). true_account/session sono garantiti da require_authentication (che
  # precede i guard god), come nel gate otp originale di Valhalla → niente `&.` (nessun ramo nil da coprire).
  # - 2FA non attivo → enrollment (lo configura e rientra).
  # - 2FA attivo ma la SESSIONE non è mai passata dal secondo fattore (difesa: sessione creata prima
  #   dell'attivazione del 2FA, sopravvissuta) → termina la sessione e rimanda al login col 2FA.
  def require_god_two_factor!
    unless Current.true_account.otp_enabled?
      redirect_to account_two_factor_path, alert: t("valhalla.two_factor_required")
      return true
    end
    return false if Current.session.two_factor_verified?

    terminate_session
    redirect_to login_path, alert: t("valhalla.two_factor_reverify")
    true
  end

  def terminate_session
    # simplecov:disable terminate_session è invocato solo dal logout (auth-required → resume_session popola
    # Current.session) → il ramo `Current.session&` nil è difesa irraggiungibile.
    Current.session&.destroy
    # simplecov:enable
    cookies.delete(:session_id)
    Current.session = nil
    Current.true_account = nil
    Current.account = nil
  end
end
