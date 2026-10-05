# frozen_string_literal: true

module Clusters
  module Tokens
    # Gives a cluster a new cyi_k_ token: the old one stops working at once (CYAG-22).
    class Rotate < ApplicationService
      def initialize(cluster:)
        @cluster = cluster
      end

      def call
        secret, digest, prefix = Clusters::Tokens::Issue.generate
        @cluster.update!(token_digest: digest, token_prefix: prefix, revoked_at: nil)
        Result.ok({ cluster: @cluster, secret: })
      end
    end
  end
end
