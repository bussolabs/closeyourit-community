# frozen_string_literal: true

module Analytics
  # CYRA-147 — giro periodico del rilevamento anomalie di traffico (crollo/picco). Sola lettura: accoda
  # gli allarmi rule-based; senza questo giro un crollo di traffico resterebbe invisibile finché qualcuno
  # non apre la dashboard. Cadenza oraria (config/recurring.yml), coerente con la finestra di confronto.
  class DetectTrafficAnomaliesJob < ApplicationJob
    queue_as :maintenance

    def perform
      flagged = Analytics::DetectTrafficAnomalies.call.value.to_i
      Rails.logger.info("Analytics::DetectTrafficAnomaliesJob: #{flagged} anomalie di traffico segnalate") if flagged.positive?
      flagged
    end
  end
end
