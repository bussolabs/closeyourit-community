# frozen_string_literal: true

module Auth
  class InvitationsController < BaseController
    before_action :set_invitation_by_token

    def edit
      @errors = {}
      @existing_account = existing_account?
      @signed_in_as_invitee = signed_in_as_invitee?
    end

    def update
      # The accept link is known to whoever sent the invitation: an existing account joins only
      # when its owner is the one signed in (CYRA-1042).
      if existing_account? && !signed_in_as_invitee?
        session[:return_to_after_authenticating] = edit_invitation_url(@token)
        return redirect_to login_path, alert: t("auth.invitations.login_required", email: @invitation.email)
      end

      result = Connections::AcceptInvitation.call(
        invitation: @invitation,
        name: params[:name],
        password: params[:password],
        password_confirmation: params[:password_confirmation]
      )

      if result.ok?
        accepted = result.value
        if accepted.new_account
          start_new_session_for(accepted.account)
          redirect_to after_authentication_url, notice: t("auth.invitations.accepted")
        else
          redirect_to after_authentication_url, notice: t("auth.invitations.accepted")
        end
      else
        @errors = result.error.details || {}
        @existing_account = existing_account?
        flash.now[:alert] = t("auth.registrations.failed")
        render :edit, status: :unprocessable_content
      end
    end

    private

    # Con un account già registrato su questa email, AcceptInvitation collega quello e SCARTA la
    # password del modulo (#update, ramo new_account: false). Chiederla comunque faceva scegliere una
    # password che non valeva nulla e mandava al login senza spiegare perché quella appena scelta non
    # funzionava. Non è una fuga di informazione: l'email invitata è già scritta in pagina.
    def existing_account?
      Accounts::Account.exists?(email: @invitation.email)
    end

    # true_account, not account: an impersonation must not accept on behalf of the invitee.
    def signed_in_as_invitee?
      authenticated? && Current.true_account.email == @invitation.email
    end

    def set_invitation_by_token
      @token = params[:token]
      @invitation = Connections::Invitation.find_by_token_for(:invitation, @token)

      return if @invitation && !@invitation.accepted?

      redirect_to login_path, alert: t("auth.invitations.invalid_token")
    end
  end
end
