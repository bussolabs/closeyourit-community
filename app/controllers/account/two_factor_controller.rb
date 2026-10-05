# frozen_string_literal: true

module Account
  # Enrollment del 2FA (CYRA-170) nell'area account (login richiesto, nessun contesto org — così il god,
  # che in produzione non ha membership, può configurarlo). Setup con QR + verifica del primo codice →
  # attivazione + recovery codes mostrati UNA volta; azione di disattivazione.
  class TwoFactorController < ApplicationController
    include Localizable

    # Layout "account" (CYRA-170 follow-up): topbar con menu utente + corona god, niente sidebar org →
    # navigazione per tornare all'account/uscire, god-safe (nessuna dipendenza da Current.organization).
    layout "account"

    # FIX-2 (CYRA-170): l'enrollment 2FA agisce SEMPRE sul true_account (identità reale), MAI su
    # Current.account — durante un'impersonation Current.account è la VITTIMA e il god ne manipolerebbe
    # il secondo fattore. Fuori dall'impersonation true_account coincide con Current.account. @account è
    # letto anche dalle view (show/setup).
    before_action :set_two_factor_account

    def show
    end

    # Provisiona il seme (idempotente) e mostra il QR + il form di verifica del primo codice.
    def setup
      return redirect_already_enabled if @account.otp_enabled?

      prepare_provisioning
    end

    # Verifica il primo codice TOTP: se valido attiva il 2FA e mostra i codici di recupero (una volta sola).
    # FIX-A (CYRA-170): ATTIVARE richiede anche la password corrente (speculare a #destroy). Senza, una
    # sessione RUBATA potrebbe attivare un 2FA con l'authenticator dell'attaccante e — via
    # confirm_two_factor_session! — revocare le altre sessioni, chiudendo fuori il legittimo in modo
    # persistente (nemmeno il reset password toglie il 2FA). Password prima del codice.
    def enable
      return redirect_already_enabled if @account.otp_enabled?

      unless @account.authenticate(params[:password].to_s)
        prepare_provisioning
        flash.now[:alert] = t("account.two_factor.activate_reauth_failed")
        return render :setup, status: :unprocessable_content
      end

      if @account.verify_otp(params[:code])
        @recovery_codes = @account.enable_otp!
        confirm_two_factor_session!
        render :recovery_codes
      else
        prepare_provisioning
        flash.now[:alert] = t("account.two_factor.invalid_code")
        render :setup, status: :unprocessable_content
      end
    end

    # FIX-3 (CYRA-170): disattivare il 2FA richiede di riprovare l'identità (password corrente OPPURE un
    # codice TOTP/recupero valido). Senza, una sessione rubata rimuoverebbe il secondo fattore da sola.
    def destroy
      unless reauthenticated_for_disable?
        flash.now[:alert] = t("account.two_factor.disable_reauth_failed")
        return render :show, status: :unprocessable_content
      end

      @account.disable_otp!
      redirect_to account_two_factor_path, notice: t("account.two_factor.disabled")
    end

    private

    def set_two_factor_account
      @account = Current.true_account
    end

    # Password corrente valida, oppure un codice TOTP/recupero valido. Il `||` corto-circuita: con una
    # password valida non si consuma alcun codice TOTP/recupero.
    def reauthenticated_for_disable?
      password = params[:password].to_s
      code = params[:code].to_s
      (password.present? && @account.authenticate(password)) ||
        @account.verify_otp(code) ||
        @account.verify_recovery_code(code)
    end

    # FIX-5 (CYRA-170): la sessione dell'enrollment ha appena dimostrato il possesso del codice → la
    # marco verificata e REVOCO ogni ALTRA sessione del true_account, così nessuna sessione pre-2FA
    # sopravvive per Valhalla (gate god = otp_enabled? E sessione verificata). Current.session è garantito
    # (azione auth-required).
    def confirm_two_factor_session!
      Current.session.update_column(:two_factor_verified_at, Time.current)
      @account.sessions.where.not(id: Current.session.id).destroy_all
    end

    def prepare_provisioning
      @account.provision_otp_secret!
      @provisioning_uri = @account.otp_provisioning_uri
      @qr_svg = qr_svg(@provisioning_uri)
    end

    # SVG inline same-origin (nessuna immagine remota, nessuna data-uri esterna): CSP-safe.
    def qr_svg(uri)
      RQRCode::QRCode.new(uri).as_svg(module_size: 4, standalone: true, use_path: true, viewbox: true)
    end

    def redirect_already_enabled
      redirect_to account_two_factor_path, notice: t("account.two_factor.already_enabled")
    end
  end
end
