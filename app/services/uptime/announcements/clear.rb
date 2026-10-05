# frozen_string_literal: true

module Uptime
  module Announcements
    # Rimuove il banner del monitor (idempotente: nessun banner → no-op).
    class Clear < ApplicationService
      def initialize(monitor:, actor: nil)
        @monitor = monitor
        @actor = actor
      end

      def call
        @monitor.announcement&.destroy
        Result.ok(nil)
      end
    end
  end
end
