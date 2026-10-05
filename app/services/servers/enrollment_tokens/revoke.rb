# frozen_string_literal: true

module Servers
  module EnrollmentTokens
    # Revoca un token della flotta (soft: imposta revoked_at). Idempotente: ri-revocare è no-op.
    class Revoke < ApplicationService
      def initialize(token:)
        @token = token
      end

      def call
        @token.update!(revoked_at: Time.current) unless @token.revoked?
        Result.ok(@token)
      end
    end
  end
end
