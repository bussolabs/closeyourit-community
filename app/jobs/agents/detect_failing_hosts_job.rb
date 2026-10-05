# frozen_string_literal: true

module Agents
  # Giro periodico dell'allarme "una macchina butta via il lavoro" (CYRA-282): un host che fallisce una
  # quota anomala di lavorazioni nella finestra viene segnalato via Alerting. Complemento del giro gemello
  # Agents::DetectStalledAttemptsJob (org che gira a vuoto): quello tace se un altro host progredisce,
  # questo guarda il singolo host — il caso reale del ticket (una macchina con l'88% di fallimenti mentre
  # l'altra lavorava). Sola lettura: rende visibile un degrado altrimenti silenzioso.
  class DetectFailingHostsJob < ApplicationJob
    queue_as :maintenance

    def perform
      flagged = Agents::Attempts::DetectFailingHosts.call.value.to_i
      Rails.logger.info("Agents::DetectFailingHostsJob: #{flagged} macchine in errore segnalate") if flagged.positive?
      flagged
    end
  end
end
