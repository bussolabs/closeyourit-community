# frozen_string_literal: true

module Agents
  # Controllo periodico delle lavorazioni ORFANE (CYRA-201): prenotazione scaduta e nessuna consegna.
  # Prima di questo job nessuna voce di `recurring.yml` riguardava `Agents::*`, quindi nessuno si accorgeva
  # di una lavorazione morta: restava "in corso" per sempre. Idempotente — un secondo giro non trova più
  # nulla da chiudere, perché `stale` è terminale e lo scope guarda solo i `running`.
  class MarkStaleAttemptsJob < ApplicationJob
    queue_as :maintenance

    def perform
      # CYRA-1113 — una riga per ogni chiusura, con ticket, fase, esecuzione e motivo: il conteggio da solo
      # non si confronta con il registro della macchina, che ragiona per run.
      result = Agents::Attempts::MarkStale.call { |attempt| log_closure(attempt) }
      marked = result.value.to_i
      # Il silenzio è il vizio che questo giro corregge: se ha chiuso qualcosa lo dice, così l'operatore
      # vede quante lavorazioni sono morte senza consegnare invece di scoprirlo da una pagina piena.
      Rails.logger.info("Agents::MarkStaleAttemptsJob: #{marked} lavorazioni ferme chiuse") if marked.positive?
      marked
    end

    private

    def log_closure(attempt)
      Rails.logger.info(
        "Agents::MarkStaleAttemptsJob: lavorazione ferma chiusa ticket=#{attempt.workflow.ticket.code} " \
        "phase=#{attempt.phase} run=#{attempt.external_run_id} host=#{attempt.host_id} " \
        "attempt=#{attempt.id} reason=#{attempt.failure_reason}"
      )
    end
  end
end
