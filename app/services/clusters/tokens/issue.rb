# frozen_string_literal: true

module Clusters
  module Tokens
    # Creates a cluster with its cyi_k_ token. The secret is returned once; only its SHA-256 digest
    # is stored (pattern Servers::EnrollmentTokens::Issue, CYAG-22).
    class Issue < ApplicationService
      SECRET_RANDOM_LENGTH = 40
      DISPLAY_PREFIX_LENGTH = 14

      def self.generate
        secret = "#{Clusters::Constants::TOKEN_PREFIX}#{SecureRandom.alphanumeric(SECRET_RANDOM_LENGTH)}"
        [ secret, Digest::SHA256.hexdigest(secret), secret[0, DISPLAY_PREFIX_LENGTH] ]
      end

      def initialize(organization:, name:, color: nil, created_by: nil)
        @organization = organization
        @name = name
        @color = color
        @created_by = created_by
      end

      def call
        secret, digest, prefix = self.class.generate
        cluster = @organization.clusters.create!(
          name: @name, color: @color, created_by: @created_by, token_digest: digest, token_prefix: prefix
        )
        Result.ok({ cluster:, secret: })
      rescue ActiveRecord::RecordInvalid => e
        Result.err(AppError.new(e.message, code: "R422-CLUSTER-002", details: e.record.errors.as_json))
      end
    end
  end
end
