# frozen_string_literal: true

module Servers
  # CYRA-809 — la rete per l'azione operativa rimasta a metà su una macchina che non torna. La strada
  # ordinaria è l'agent al ritorno (Servers::Actions::Claim chiama la riconciliazione da sé), ma
  # presuppone appunto un ritorno: una macchina spenta, dismessa o con la credenziale revocata non si
  # presenta più, e la sua azione resterebbe "in corso" per sempre a occupare l'unico posto attivo.
  # Idempotente — un secondo giro non trova più niente, perché guarda solo queued e running.
  class ReconcileActionsJob < ApplicationJob
    queue_as :maintenance

    def perform
      reconciled = Servers::Actions::Reconcile.call.value.to_i
      # Il silenzio è il vizio che questo giro corregge: quante azioni sono morte senza dirlo deve
      # leggersi nei log, non scoprirsi da una pagina ferma.
      Rails.logger.info("Servers::ReconcileActionsJob: #{reconciled} azioni rimaste a metà chiuse") if reconciled.positive?
      reconciled
    end
  end
end
