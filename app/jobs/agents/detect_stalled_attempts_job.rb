# frozen_string_literal: true

module Agents
  # Giro periodico dell'allarme "lavorazioni bloccate" (CYRA-212, Scenario 2): con host attivi ma nessun
  # risultato buono nella finestra, il sistema gira a vuoto e — prima di questo — nessuno se ne accorgeva.
  # Sola lettura: rende visibile un degrado altrimenti silenzioso, accodando l'evento di allarme; il
  # rimedio (riaprire le fasi) vive nel giro gemello Agents::MarkStaleAttemptsJob.
  class DetectStalledAttemptsJob < ApplicationJob
    queue_as :maintenance

    def perform
      flagged = Agents::Attempts::DetectStalled.call.value.to_i
      Rails.logger.info("Agents::DetectStalledAttemptsJob: #{flagged} organizzazioni a vuoto segnalate") if flagged.positive?
      flagged
    end
  end
end
