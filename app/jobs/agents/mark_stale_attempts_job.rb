# frozen_string_literal: true

module Agents
  # Controllo periodico delle lavorazioni ORFANE (CYRA-201): prenotazione scaduta e nessuna consegna.
  # Prima di questo job nessuna voce di `recurring.yml` riguardava `Agents::*`, quindi nessuno si accorgeva
  # di una lavorazione morta: restava "in corso" per sempre. Idempotente — un secondo giro non trova più
  # nulla da chiudere, perché `stale` è terminale e lo scope guarda solo i `running`.
  class MarkStaleAttemptsJob < ApplicationJob
    queue_as :maintenance

    def perform
      result = Agents::Attempts::MarkStale.call
      marked = result.value.to_i
      # Il silenzio è il vizio che questo giro corregge: se ha chiuso qualcosa lo dice, così l'operatore
      # vede quante lavorazioni sono morte senza consegnare invece di scoprirlo da una pagina piena.
      Rails.logger.info("Agents::MarkStaleAttemptsJob: #{marked} lavorazioni ferme chiuse") if marked.positive?
      marked
    end
  end
end
