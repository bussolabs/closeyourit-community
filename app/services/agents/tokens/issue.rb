# frozen_string_literal: true

module Agents
  module Tokens
    # Emette il token org-scoped usato esclusivamente per registrare un'installazione Automator. Il
    # segreto è mostrato UNA sola volta nel Result; in DB solo il digest SHA-256 (pattern
    # Servers::EnrollmentTokens::Issue, prefisso cyi_a_).
    class Issue < ApplicationService
      SECRET_RANDOM_LENGTH = 40   # alphanumeric → ~238 bit
      DISPLAY_PREFIX_LENGTH = 14  # "cyi_a_" + 8 char mostrati in chiaro

      def initialize(organization:, name:, created_by: nil)
        @organization = organization
        @name = name
        @created_by = created_by
      end

      def call
        secret = "#{Agents::Constants::TOKEN_PREFIX}#{SecureRandom.alphanumeric(SECRET_RANDOM_LENGTH)}"

        token = @organization.agent_tokens.create!(
          name: @name,
          created_by: @created_by,
          token_digest: Digest::SHA256.hexdigest(secret),
          token_prefix: secret[0, DISPLAY_PREFIX_LENGTH]
        )

        Result.ok({ token:, secret: })
      rescue ActiveRecord::RecordInvalid => e
        Result.err(AppError.new(e.message, code: "R422-AGENT-003", details: e.record.errors.as_json))
      end
    end
  end
end
