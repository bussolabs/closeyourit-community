# frozen_string_literal: true

module Alerting
  # CYRA-1228 — la rete sotto agli avvisi di fermo di server, cluster e lavori pianificati: consegna
  # quelli che il controllo ha segnato giù e non è riuscito ad affidare alla coda.
  class ReconcileOutagesJob < ApplicationJob
    queue_as :maintenance
    limits_concurrency to: 1, key: "periodic", duration: 5.minutes, on_conflict: :discard

    def perform
      recovered = Alerting::ReconcileOutages.call.value.to_i
      # WARN e non INFO: un avviso recuperato vuol dire che la consegna normale non ha funzionato, ed
      # è l'unico posto in cui quel guasto si vede.
      if recovered.positive?
        Rails.logger.warn("Alerting::ReconcileOutagesJob: #{recovered} avvisi di fermo recuperati")
      end
      recovered
    end
  end
end
