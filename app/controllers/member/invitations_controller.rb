# frozen_string_literal: true

module Member
  class InvitationsController < Member::BaseController
    before_action :require_management

    def new
      @invitation = Current.organization.invitations.new
    end

    def create
      result = Connections::InviteMember.call(
        organization: Current.organization,
        email: params[:email],
        role: params[:role],
        invited_by: Current.account
      )
      if result.ok?
        redirect_to member_members_path, notice: t("member.invitations.sent")
      else
        @invitation = Current.organization.invitations.new(email: params[:email], role: params[:role])
        @error = result.error.message
        render :new, status: :unprocessable_content
      end
    end

    def resend
      Connections::InvitationsMailer.invite(scoped_invitation).deliver_later
      redirect_to member_members_path, notice: t("member.invitations.resent")
    end

    def destroy
      scoped_invitation.destroy!
      redirect_to member_members_path, notice: t("member.invitations.revoked")
    end

    private

    def scoped_invitation
      Current.organization.invitations.find(params[:id])
    end

    def require_management
      require_permission!("members.invite")
    end
  end
end
