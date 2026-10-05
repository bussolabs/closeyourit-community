# frozen_string_literal: true

module Auth
  class PasswordsController < BaseController
    before_action :set_account_by_token, only: %i[edit update]

    # Richiesta reset: form email
    def new
    end

    # Invia il link di reset. Risposta sempre generica (niente enumeration delle email).
    def create
      account = Accounts::Account.find_by(email: params[:email])
      Auth::PasswordsMailer.reset(account).deliver_later if account

      redirect_to login_path, notice: t("auth.passwords.sent")
    end

    # Form nuova password (raggiunto dal token)
    def edit
      @errors = {}
    end

    def update
      if @account.update(password: params[:password], password_confirmation: params[:password_confirmation])
        revoke_other_sessions
        revoke_api_tokens
        redirect_to login_path, notice: t("auth.passwords.updated")
      else
        @errors = @account.errors.to_hash
        flash.now[:alert] = t("auth.registrations.failed")
        render :edit, status: :unprocessable_content
      end
    end

    private

    # CYRA-170 (B): dopo un cambio password tutte le sessioni ESISTENTI dell'account cadono — un reset
    # è la reazione tipica a un account compromesso, quindi ogni cookie di sessione aperto (incluso quello
    # dell'attaccante) deve morire. Nel flusso di reset l'utente NON è loggato → Current.session è nil →
    # `where.not(id: nil)` = tutte le sessioni. La stessa chiamata varrebbe per un futuro cambio-password
    # volontario (utente loggato), dove preserverebbe la sola sessione corrente: oggi quel flusso non
    # esiste (in area member/account non c'è pagina di cambio password: solo reset via token).
    def revoke_other_sessions
      @account.sessions.where.not(id: Current.session&.id).destroy_all
    end

    # CYRA-643: il reset chiude anche le credenziali della riga di comando. Le sessioni del browser
    # cadevano già, ma un token CLI vive in una tabella diversa e sopravviveva al reset — chi aveva
    # rubato il portatile restava dentro dal terminale con la password nuova addosso. Nessuna
    # eccezione per il "dispositivo corrente": qui l'utente NON è loggato via token (è nel flusso web
    # del reset), e chi sta reagendo a un furto vuole proprio che ricomincino tutti da capo.
    def revoke_api_tokens
      Accounts::ApiTokens::RevokeAll.call(account: @account)
    end

    def set_account_by_token
      @token = params[:token]
      @account = Accounts::Account.find_by_token_for(:password_reset, @token)

      redirect_to new_password_path, alert: t("auth.passwords.invalid_token") if @account.nil?
    end
  end
end
