# frozen_string_literal: true

module Agents
  module Hosts
    # Ends a pause: the machine takes work again from its next request. Idempotent.
    class Resume < ApplicationService
      def initialize(host:)
        @host = host
      end

      def call
        @host.update!(paused_at: nil, paused_by: nil, paused_until: nil, pause_reason: nil)
        Result.ok(@host)
      end
    end
  end
end
