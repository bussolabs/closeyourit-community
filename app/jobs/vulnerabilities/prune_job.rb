# frozen_string_literal: true

module Vulnerabilities
  # Pota gli advisory che non colpiscono più nessuno.
  #
  # I finding NON si potano: sono la memoria di cosa è stato trovato e quando, ed è quella che
  # permette di dire «questa falla è rimasta aperta tre mesi». Gli advisory orfani invece sono solo
  # una cache: se nessun finding li punta, nessuno li leggerà mai più, e la prossima scansione che ne
  # avesse bisogno li riscarica in una richiesta.
  class PruneJob < ApplicationJob
    queue_as :batch

    def perform
      Vulnerabilities::Advisory
        .where.missing(:findings)
        .where(refreshed_at: ...Vulnerabilities::Constants::ADVISORY_REFRESH_AFTER.ago)
        .in_batches(&:delete_all)
    end
  end
end
