# frozen_string_literal: true

module Usage
  # CYSK-29 — un simbolo non più visto da oltre la retention esce dalla tabella: se torna, rientra
  # con un first_seen_at nuovo. 400 giorni: abbastanza da coprire un giro annuale (job stagionali)
  # con un margine, senza tenere per sempre simboli di codice ormai rimosso.
  class PruneJob < ApplicationJob
    queue_as :batch

    RETENTION = 400.days

    def perform
      ::Usage::Symbol.where(last_seen_at: ...RETENTION.ago).in_batches(&:delete_all)
    end
  end
end
