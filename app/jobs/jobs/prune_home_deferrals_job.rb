# frozen_string_literal: true

module Jobs
  # Retention dei rimandi della home (CYRA-654).
  #
  # Un rimando scaduto non nasconde più niente — `Home::Deferral.live` lo esclude già — ma resta
  # scritto: chi rimanda cinque card al giorno lascia dietro di sé un migliaio di righe l'anno che
  # nessuno leggerà mai.
  #
  # Pota anche gli ORFANI di fatto: una card cancellata (ticket eliminato, lavorazione annullata)
  # lascia una `card_key` che non risolverà mai più. Non serve andarli a cercare uno per uno —
  # scadono e cadono di qui con tutti gli altri.
  class PruneHomeDeferralsJob < ApplicationJob
    queue_as :batch

    # Due giorni oltre la scadenza: la finestra in cui il dato può ancora spiegare perché ieri una
    # card era sparita. Oltre, è archeologia di una preferenza di lettura.
    RETENTION = 2.days

    def perform
      ::Home::Deferral.where(until_at: ..RETENTION.ago).delete_all
    end
  end
end
