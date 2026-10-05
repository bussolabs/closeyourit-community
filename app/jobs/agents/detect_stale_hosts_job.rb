# frozen_string_literal: true

module Agents
  # Giro periodico dell'allarme "una macchina è ferma" (CYRA-450): un host che non batte da oltre la soglia
  # di allarme viene segnalato via Alerting. Gemello per-host di DetectFailingHostsJob, ma sul silenzio
  # (macchina che non risponde) invece che sulla quota di fallimenti (macchina che gira ma sbaglia). Sola
  # lettura: rende visibile un degrado altrimenti silenzioso.
  class DetectStaleHostsJob < ApplicationJob
    queue_as :maintenance

    def perform
      flagged = Agents::Hosts::DetectStale.call.value.to_i
      Rails.logger.info("Agents::DetectStaleHostsJob: #{flagged} macchine ferme segnalate") if flagged.positive?
      flagged
    end
  end
end
