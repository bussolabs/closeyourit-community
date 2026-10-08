# frozen_string_literal: true

module Agents
  module Hosts
    # A secret the organization lends to its machines, served to one of its certified hosts (CYAU-224 Claude,
    # CYAU-228 OpenRouter). The only path through which the token leaves the database.
    class LentCredential < ApplicationService
      # What a host is told when it is refused: no credential → it uses its own login (Claude) or no machine
      # reviews with OpenCode (OpenRouter).
      REFUSALS = {
        claude_credential: {
          not_certified: [ "Host is not certified: no Claude credential is served", "R403-AGENT-003" ],
          none: [ "The organization has no Claude credential for its machines", "R404-AGENT-005" ]
        },
        openrouter_credential: {
          not_certified: [ "Host is not certified: no OpenRouter key is served", "R403-AGENT-008" ],
          none: [ "The organization has no OpenRouter key for its machines", "R404-AGENT-006" ]
        }
      }.freeze

      def initialize(host:, credential:)
        @host = host
        @credential = credential
      end

      def call
        return refuse(:not_certified, :forbidden) unless @host.certified?

        served = candidates.lazy.filter_map(&:served).first
        return refuse(:none, :not_found) if served.nil?

        Result.ok(served)
      end

      private

      # CYRA-1052 — the machine's own Claude credential first, then the organization's.
      def candidates
        own = @host.claude_credential if @credential == :claude_credential
        [ own, @host.organization.public_send(@credential) ].compact
      end

      def refuse(reason, status)
        message, code = REFUSALS.fetch(@credential).fetch(reason)
        Result.err(AppError.new(message, code: code, status: status))
      end
    end
  end
end
