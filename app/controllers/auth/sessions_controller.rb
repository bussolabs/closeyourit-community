# frozen_string_literal: true

module Auth
  class SessionsController < BaseController
    # new/create restano pubblici (da BaseController); il logout richiede una sessione attiva
    # così `resume_session` popola Current.session prima di terminarla.
    before_action :require_authentication, only: :destroy

    def new
    end

    def create
      account = Accounts::Account.find_by(email: params[:email])

      # I service account (non-umani, CLI-only) NON fanno login web: anche con le credenziali giuste
      # niente sessione. Stesso messaggio generico degli altri fallimenti (non si rivela il tipo account).
      if account&.human? && account.authenticate(params[:password])
        if account.otp_enabled?
          # 2FA attivo: password superata ma sessione NON ancora creata. Si chiede il secondo fattore.
          start_two_factor_challenge(account)
          redirect_to two_factor_challenge_path
        else
          start_new_session_for(account)
          redirect_to after_authentication_url, notice: t("auth.sessions.signed_in")
        end
      else
        flash.now[:alert] = t("auth.sessions.invalid")
        render :new, status: :unprocessable_content
      end
    end

    def destroy
      terminate_session
      redirect_to login_path, notice: t("auth.sessions.signed_out")
    end
  end
end
