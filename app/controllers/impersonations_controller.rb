# frozen_string_literal: true

# Impersonation god → account. Top-level (NON sotto Valhalla::BaseController): durante
# l'impersonazione Current.account è il membro non-god, quindi il guard god bloccherebbe l'uscita.
class ImpersonationsController < ApplicationController
  include Localizable

  # Layout god: l'unica azione che RENDE qualcosa è la conferma (new, e il suo re-render dopo un codice
  # rifiutato), raggiunta solo da un god non ancora impersonato. create/destroy reindirizzano sempre,
  # quindi il layout non entra mai in gioco mentre Current.account è la vittima.
  layout "valhalla"

  before_action :require_god_impersonator!, only: %i[new create]
  before_action :set_impersonation_target, only: %i[new create]

  # Conferma prima di entrare nei panni di qualcuno (CYRA-719): mostra il bersaglio e chiede di nuovo
  # il codice del secondo fattore.
  def new
  end

  def create
    # Soglia raggiunta: la sessione muore prima ancora di guardare il codice, altrimenti il conteggio
    # sarebbe aggirabile continuando a provare (vedi reauth_failure_key).
    return lock_out_reauth if reauth_attempts_exhausted?

    # FIX (CYRA-719): re-auth SULL'AVVIO, non solo al login. La sessione god è già passata dal secondo
    # fattore (require_god_two_factor!), ma un cookie rubato la eredita: senza ridimostrare il possesso
    # dell'authenticator, chi ruba una sessione god entra nei panni di chiunque con una sola POST.
    # Solo TOTP: i codici di recupero sono monouso e servono a rientrare quando l'authenticator manca,
    # bruciarli qui lascerebbe il god senza la sua via di rientro.
    unless Current.true_account.verify_otp(params[:code])
      register_failed_reauth_attempt
      return lock_out_reauth if reauth_attempts_exhausted?

      flash.now[:alert] = t("impersonations.confirm.invalid_code")
      return render :new, status: :unprocessable_content
    end

    clear_reauth_attempts
    start_impersonation(@target)

    if @organization
      session[:organization_id] = @organization.id
      redirect_to root_path, notice: t("impersonations.entered", name: @organization.name)
    else
      redirect_to root_path, notice: t("impersonations.started", email: @target.email)
    end
  end

  def destroy
    session = Current.session

    # simplecov:disable destroy è auth-required (Authentication in ApplicationController) → Current.session sempre
    # presente nell'azione; il ramo `session&` nil è difesa irraggiungibile.
    if session&.impersonating?
      # simplecov:enable
      Accounts::ImpersonationEvent
        .open.where(god_id: session.account_id, account_id: session.impersonated_account_id)
        .order(:created_at).last&.close!
      Rails.logger.warn("Impersonation stopped god_id=#{session.account_id} account_id=#{session.impersonated_account_id}")
      session.update!(impersonated_account: nil)
    end

    redirect_to valhalla_root_path, notice: t("impersonations.stopped")
  end

  private

  # Bersaglio dell'impersonation, condiviso da `new` (conferma) e `create` (avvio): un account preso
  # direttamente dal kebab di Valhalla::Accounts, oppure il rappresentante di un'organizzazione (owner,
  # con fallback al primo membro). Gli esiti impossibili — se stesso, organizzazione senza membri —
  # fermano già la CONFERMA: chiedere un codice per poi rifiutare il bersaglio brucerebbe un codice
  # TOTP (che è monouso nella sua finestra) per un'azione che non poteva riuscire.
  def set_impersonation_target
    if params[:organization_id].present?
      @organization = Organizations::Organization.find(params[:organization_id])
      @target = @organization.owner || @organization.memberships.order(:created_at).first&.account

      if @target.nil? || @target == Current.true_account
        redirect_to(valhalla_organization_path(@organization), alert: t("impersonations.no_member"))
      end
    else
      @target = Accounts::Account.find(params[:account_id])

      redirect_to(valhalla_accounts_path, alert: t("impersonations.cannot_self")) if @target == Current.true_account
    end
  end

  # Tentativi falliti della riprova del secondo fattore, contati SULLA SESSIONE (CYRA-719). Il throttle
  # rack-attack frena un indirizzo per volta, ma il cookie rubato si usa da mille indirizzi diversi e il
  # codice è di sei cifre: senza questo conteggio il brute-force distribuito resta praticabile. Stessa
  # forma del lockout della challenge di login (FIX-H/FIX-J di CYRA-170): contatore SERVER-SIDE in
  # Rails.cache — la rack session è un CookieStore, che un attaccante rigiocherebbe azzerato — su una
  # chiave che porta il DIGEST dell'id di sessione, mai l'id in chiaro (finisce in cache e nei log).
  # Incremento ATOMICO cache-native: un read-modify-write perderebbe conteggi con richieste concorrenti,
  # che è esattamente la forma di un brute-force. Il fallback write copre gli store che tornano nil su
  # chiave assente.
  def register_failed_reauth_attempt
    Rails.cache.increment(reauth_failure_key, 1, expires_in: Accounts::Constants::IMPERSONATION_REAUTH_TTL) ||
      Rails.cache.write(reauth_failure_key, 1, expires_in: Accounts::Constants::IMPERSONATION_REAUTH_TTL)
  end

  def reauth_attempts_exhausted?
    Rails.cache.read(reauth_failure_key).to_i >= Accounts::Constants::OTP_MAX_ATTEMPTS
  end

  # Azzerato SOLO da un avvio riuscito: chi possiede davvero l'authenticator riparte con tutti i
  # tentativi, chi tira a indovinare no.
  def clear_reauth_attempts
    Rails.cache.delete(reauth_failure_key)
  end

  def reauth_failure_key
    "impersonation_reauth_fails:#{Digest::SHA256.hexdigest(Current.session.id)}"
  end

  # Esauriti i tentativi la sessione MUORE, non si limita a rifiutare: è la sola risposta che toglie
  # valore al cookie rubato con cui il brute-force veniva tentato. Il god legittimo rientra dal login,
  # che ha già il suo freno per indirizzo e il secondo fattore.
  def lock_out_reauth
    Rails.logger.warn(
      "Impersonation reauth lockout god_id=#{Current.true_account.id} session_id=#{Current.session.id}"
    )
    terminate_session
    redirect_to login_path, alert: t("impersonations.confirm.locked_out")
  end

  def start_impersonation(target)
    Current.session.update!(impersonated_account: target)
    Accounts::ImpersonationEvent.create!(god: Current.true_account, account: target, started_at: Time.current)
    Rails.logger.warn("Impersonation started god_id=#{Current.true_account.id} account_id=#{target.id}")
  end

  # Gate solo sull'AVVIO impersonation (conferma + create). L'USCITA (destroy) NON è mai gated,
  # altrimenti un god senza 2FA/sessione-verificata resterebbe intrappolato nell'impersonation.
  def require_god_impersonator!
    # Current.true_account è garantito da require_authentication (precede questo guard). Il ramo non-god è
    # RAGGIUNGIBILE (utente autenticato non-god che tenta l'impersonation) e coperto da spec (FIX-F).
    return redirect_to(root_path, alert: t("valhalla.unauthorized")) unless Current.true_account.god?

    # FIX-10 (CYRA-170): l'impersonation è top-level (NON sotto Valhalla::BaseController) → il gate 2FA di
    # FIX-5 non la coprirebbe. Applico lo STESSO gate qui: senza 2FA (o senza sessione verificata) un
    # attaccante con la sola password del god otterrebbe la capacità god più pericolosa aggirando il 2FA.
    require_god_two_factor!
  end
end
