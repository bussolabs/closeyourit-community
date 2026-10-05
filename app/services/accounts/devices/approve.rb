# frozen_string_literal: true

module Accounts
  module Devices
    # Approvazione browser (umano loggato). Registra account + org scelta e marca approved. NON conia il
    # token: il segreto viene consegnato solo alla CLI al poll (mai dal browser). Guard anti-BOLA:
    # l'umano dev'essere membro dell'org scelta.
    class Approve < ApplicationService
      def initialize(grant:, account:, organization:)
        @grant = grant
        @account = account
        @organization = organization
      end

      def call
        return not_approvable unless @grant.approvable?

        unless Connections::Membership.exists?(account_id: @account.id, organization_id: @organization.id)
          return Result.err(AppError.new("Organizzazione non valida",
                                         code: "R404-SYSTEM-001", status: :not_found))
        end

        return not_approvable unless approve!

        Result.ok(@grant.reload)
      end

      private

      # `approvable?` legge uno snapshot, e fra quella lettura e questa scrittura la concessione può
      # essere stata negata (o consumata) da un'altra richiesta: la condizione va rimessa DENTRO la
      # UPDATE, altrimenti l'approvazione cieca riporterebbe ad `approved` un rifiuto già espresso
      # dall'umano — e da lì uscirebbe una credenziale (CYRA-806). `live` è la stessa definizione di
      # "ancora approvabile" del modello: in attesa e non scaduta.
      def approve!
        Accounts::DeviceGrant.live.where(id: @grant.id).update_all(
          account_id: @account.id, organization_id: @organization.id,
          status: :approved, approved_at: Time.current, updated_at: Time.current
        ).positive?
      end

      def not_approvable
        Result.err(AppError.new("Concessione scaduta o non valida",
                                code: "R400-CLIAUTH-005", status: :bad_request))
      end
    end
  end
end
