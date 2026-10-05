# frozen_string_literal: true

module Servers
  module HostTokens
    class Issue < ApplicationService
      def initialize(host:) = @host = host

      def call
        secret = "cyi_h_#{SecureRandom.alphanumeric(40)}"
        token = @host.host_tokens.create!(
          token_digest: Digest::SHA256.hexdigest(secret), token_prefix: secret.first(14)
        )
        Result.ok({ token:, secret: })
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
        Result.err(AppError.new(e.message, code: "R422-SERVER-005"))
      end
    end
  end
end
