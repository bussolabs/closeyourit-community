# frozen_string_literal: true

module Accounts
  module Devices
    # Token endpoint del device-flow (RFC 8628 §3.4-3.5). Risolve il grant dal device_code e decide:
    #   - device_code sconosciuto       → invalid_grant (401)
    #   - scaduto                       → expired_token
    #   - negato                        → access_denied
    #   - poll troppo frequente         → slow_down (alza interval)
    #   - ancora pending                → authorization_pending
    #   - già consumato (fulfilled)     → access_denied (single-use)
    #   - approvato                     → conia il token ORA, consegna il segreto UNA volta, fulfilled
    # L'envelope casa è {error:{code,message,details}}, con details.oauth_error = stringa RFC esatta per
    # far branchare la CLI sul valore standard.
    class Poll < ApplicationService
      SLOW_DOWN_BUMP = 5

      def initialize(device_code:)
        @device_code = device_code
      end

      def call
        grant = Accounts::DeviceGrant.find_by(device_code_digest: digest)
        return invalid_grant if grant.nil?
        return expire(grant) if grant.expires_at <= Time.current
        return denied if grant.denied?
        return slow_down(grant) if too_fast?(grant)

        grant.update_column(:last_polled_at, Time.current)

        return pending if grant.pending?
        return already_fulfilled if grant.fulfilled?

        mint(grant) # approved
      end

      private

      def digest = Digest::SHA256.hexdigest(@device_code)

      # Emissione e consumo sono UN atto solo (CYRA-806). Il token nasce dentro la stessa transazione
      # che marca fulfilled, e la marcatura è `consume`: chi arriva secondo non consuma niente e si
      # porta via col rollback la credenziale appena coniata. Con la sola guardia sull'oggetto in
      # memoria due poll simultanei leggevano entrambi `approved` — e da una concessione dichiarata
      # monouso uscivano due credenziali, entrambe valide.
      #
      # `requires_new: true` non è decorativo: `ActiveRecord::Rollback` dentro un blocco soltanto
      # UNITO a una transazione esterna viene ingoiato senza annullare niente, e la credenziale mai
      # consegnata resterebbe in piedi e utilizzabile.
      def mint(grant)
        outcome = nil
        Accounts::DeviceGrant.transaction(requires_new: true) do
          outcome = issue_and_consume(grant)
          raise ActiveRecord::Rollback if outcome.err?
        end
        outcome
      end

      def issue_and_consume(grant)
        issued = Accounts::ApiTokens::Issue.call(
          account: grant.account, organization: grant.organization,
          name: grant.client_name.presence || "CLI"
        )
        return Result.err(issued.error) if issued.err?

        token = issued.value[:token]
        return already_fulfilled unless consume(grant, token)

        Result.ok({ access_token: issued.value[:secret], token:, grant: })
      end

      # Il consumo è UNA istruzione: la condizione sullo stato sta nella stessa UPDATE che lo cambia,
      # quindi è il database a decidere chi vince. Chi trova zero righe è arrivato secondo.
      def consume(grant, token)
        claimed = Accounts::DeviceGrant.where(id: grant.id, status: :approved)
                                       .update_all(status: :fulfilled, api_token_id: token.id,
                                                   updated_at: Time.current)
        return false if claimed.zero?

        grant.reload
        true
      end

      def too_fast?(grant)
        grant.last_polled_at.present? && (Time.current - grant.last_polled_at) < grant.interval
      end

      def slow_down(grant)
        grant.update!(interval: grant.interval + SLOW_DOWN_BUMP, last_polled_at: Time.current)
        oauth_error("R400-CLIAUTH-003", "slow_down", "Polling troppo frequente")
      end

      def pending
        oauth_error("R400-CLIAUTH-002", "authorization_pending", "Autorizzazione in attesa")
      end

      def denied
        oauth_error("R400-CLIAUTH-005", "access_denied", "Accesso negato")
      end

      def expire(grant)
        grant.expired! unless grant.expired?
        oauth_error("R400-CLIAUTH-005", "expired_token", "Concessione scaduta")
      end

      def already_fulfilled
        oauth_error("R400-CLIAUTH-005", "access_denied", "Concessione già utilizzata")
      end

      def invalid_grant
        oauth_error("R401-CLIAUTH-001", "invalid_grant", "device_code non valido", status: :unauthorized)
      end

      def oauth_error(code, oauth, message, status: :bad_request)
        Result.err(AppError.new(message, code:, status:, details: { oauth_error: oauth }))
      end
    end
  end
end
