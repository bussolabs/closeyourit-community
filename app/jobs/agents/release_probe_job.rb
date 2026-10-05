# frozen_string_literal: true

module Agents
  # CYRA-624 — va a guardare se il rilascio in produzione è davvero in piedi.
  #
  # Le righe da controllare sono le prove ancora agganciate e scadute: è lo stesso insieme che
  # l'indice parziale copre. Nessun esito passa da un'eccezione — un job che solleva ritenta tre volte
  # e poi tace, e il silenzio qui sarebbe indistinguibile da «il rilascio è andato bene».
  class ReleaseProbeJob < ApplicationJob
    queue_as :maintenance

    # Ogni riga costa fino a tre chiamate a GitHub: senza un tetto, un arretrato le farebbe partire
    # tutte insieme e il rate limit le farebbe fallire in blocco.
    BATCH = 25

    def perform(workflow_id = nil)
      # Il lotto è già limitato: find_each scarterebbe l'ordine di scadenza.
      probes(workflow_id).each do |probe|
        Agents::Probes::Observe.call(probe:)
      rescue StandardError => e
        Rails.logger.error("Agents::ReleaseProbeJob: #{probe.id} #{e.class}: #{e.message}")
      end
    end

    private

    def probes(workflow_id)
      return Agents::WorkflowProbe.live.where(workflow_id:) if workflow_id

      Agents::WorkflowProbe.due.order(:next_check_at).limit(BATCH)
    end
  end
end
