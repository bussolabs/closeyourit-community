# frozen_string_literal: true

module Cli
  module V1
    module Invitations
      # Reinvio di un invito come sub-resource singleton: PUT = riaccoda la mail e RIVELA di nuovo
      # l'accept_url (token firmato), come fa la create, insieme a email_delivery (se la posta è spenta
      # il link va consegnato a mano — lo decide il server, non una frase fissa nella CLI).
      # Gate `members.invite`. Scoping org (anti-BOLA). Non crea nulla → status :ok.
      class ResendsController < Cli::V1::BaseController
        before_action :set_invitation
        before_action -> { require_permission!("members.invite") }

        def update
          Connections::InvitationsMailer.invite(@invitation).deliver_later
          accept_url = "#{request.base_url}#{edit_invitation_path(@invitation.generate_token_for(:invitation))}"
          render json: { data: InvitationSerializer.new(@invitation).as_json
                                                   .merge("accept_url" => accept_url,
                                                          "email_delivery" => ActionMailer::Base.perform_deliveries) },
                 status: :ok
        end

        private

        # Anti-BOLA: invito dentro l'org corrente → id di altra org → R404 (prima del gate).
        def set_invitation
          @invitation = Current.organization.invitations.find(params[:invitation_id])
        end
      end
    end
  end
end
