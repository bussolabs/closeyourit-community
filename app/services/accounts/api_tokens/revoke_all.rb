# frozen_string_literal: true

module Accounts
  module ApiTokens
    # Revoca in blocco i token CLI ATTIVI di un account (soft: revoked_at). Serve dove la reazione è
    # "questo account non è più fidato": reset password (CYRA-643) e, in prospettiva, ogni riprova
    # d'identità fallita. Una UPDATE sola invece di N: la revoca è un fatto senza callback, e un giro
    # di `each` su un account con molti dispositivi lascerebbe la finestra in cui metà token vive
    # ancora. Idempotente per costruzione: lo scope `active` non contiene i già revocati, quindi
    # revoked_at non viene mai riscritto (la data della PRIMA revoca è il dato che si legge nella
    # lista). `keep:` esclude un token — il chiamante che sta usando la CLI in quel momento.
    class RevokeAll < ApplicationService
      def initialize(account:, keep: nil)
        @account = account
        @keep = keep
      end

      def call
        scope = @account.api_tokens.active
        scope = scope.where.not(id: @keep.id) if @keep
        Result.ok(scope.update_all(revoked_at: Time.current))
      end
    end
  end
end
