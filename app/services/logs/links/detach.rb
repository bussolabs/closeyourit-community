# frozen_string_literal: true

module Logs
  module Links
    # Rimuove il collegamento manuale log↔errore/ticket. Idempotente: se non esiste, no-op.
    class Detach < ApplicationService
      def initialize(log_entry:, linkable:)
        @log_entry = log_entry
        @linkable = linkable
      end

      def call
        Logs::Link.where(log_entry: @log_entry, linkable: @linkable).destroy_all
        Result.ok(true)
      end
    end
  end
end
