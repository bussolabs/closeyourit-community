# frozen_string_literal: true

module Cli
  module V1
    # Inviti all'organizzazione (onboarding cliente). Gate `members.invite`. create usa
    # Connections::InviteMember (ruolo default `customer`) e RIVELA l'accept_url (token firmato) nella
    # risposta: in prod la mail non è cablata, quindi il link va inoltrato a mano. Scoping org (anti-BOLA).
    class InvitationsController < Cli::V1::BaseController
      before_action -> { require_permission!("members.invite") }
      before_action :set_invitation, only: :destroy

      def index
        records, meta = paginate(Current.organization.invitations.order(created_at: :desc))
        render_ok(InvitationSerializer.new(records), meta: meta)
      end

      def create
        result = Connections::InviteMember.call(
          organization: Current.organization, email: params[:email],
          role: params[:role].presence || "customer", invited_by: Current.account
        )
        if result.ok?
          render_invited(result.value)
        else
          render_error(result.error.code, result.error.message,
                       status: result.error.status, details: result.error.details)
        end
      end

      def destroy
        @invitation.destroy
        render_no_content
      end

      private

      def set_invitation
        @invitation = Current.organization.invitations.find(params[:id])
      end

      # accept_url (token firmato) + email_delivery: la CLI stampava sempre "Email delivery is not
      # wired in production", una frase fissa che non guardava niente e che quindi non distingueva la
      # posta spenta da quella funzionante. Solo il server lo sa: perform_deliveries è false quando
      # RESEND_API_KEY manca (config/environments/production.rb).
      def render_invited(invitation)
        accept_url = "#{request.base_url}#{edit_invitation_path(invitation.generate_token_for(:invitation))}"
        render json: { data: InvitationSerializer.new(invitation).as_json
                                                 .merge("accept_url" => accept_url,
                                                        "email_delivery" => ActionMailer::Base.perform_deliveries) },
               status: :created
      end
    end
  end
end
