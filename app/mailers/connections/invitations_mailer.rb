# frozen_string_literal: true

module Connections
  class InvitationsMailer < ApplicationMailer
    def invite(invitation)
      @invitation = invitation
      @organization = invitation.organization
      @token = invitation.generate_token_for(:invitation)
      # Lingua: ApplicationMailer#process la deriva dal primo argomento (invitation.invited_by) — chi
      # invita come euristica, dato che l'invitato non ha ancora un account. invited_by nil → default.
      mail to: invitation.email,
           subject: t("connections.invitations.mailer.subject", organization: @organization.name)
    end
  end
end
