# frozen_string_literal: true

module Ai
  # Elimina le Ai::Request più vecchie di Ai::Constants::REQUESTS_RETENTION: sono draft
  # effimeri (il risultato vive nella UI che lo polla), non storico. Schedulato in recurring.yml.
  class PruneRequestsJob < ApplicationJob
    queue_as :batch

    def perform
      Ai::Request.stale.delete_all
    end
  end
end
