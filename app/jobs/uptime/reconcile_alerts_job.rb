# frozen_string_literal: true

module Uptime
  # CYRA-792 — la rete sotto agli avvisi uptime: consegna quelli che il controllo ha scritto e non è
  # riuscito ad affidare alla coda.
  #
  # Due ingressi, e servono entrambi. Il controllo successivo recupera da sé la caduta ancora in
  # corso (Uptime::RecordCheck), così nel caso normale l'avviso arriva entro il minuto; questo giro
  # copre tutto il resto — il ripristino, il monitor messo in pausa, il sito tornato su prima che un
  # altro controllo passasse di lì.
  class ReconcileAlertsJob < ApplicationJob
    queue_as :maintenance

    def perform
      recovered = Uptime::ReconcileAlerts.call.value.to_i
      # WARN e non INFO: un avviso recuperato vuol dire che la consegna normale non ha funzionato, ed
      # è l'unico posto in cui quel guasto si vede.
      if recovered.positive?
        Rails.logger.warn("Uptime::ReconcileAlertsJob: #{recovered} avvisi uptime recuperati")
      end
      recovered
    end
  end
end
