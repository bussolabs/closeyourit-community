# frozen_string_literal: true

module Agents
  # CYRA-620 — va a guardare se il codice approvato è atterrato davvero sulla linea principale.
  #
  # Le righe da controllare sono quelle consegnate e non ancora verificate, scadute: è lo stesso
  # insieme che l'indice parziale copre. Nessun esito passa da un'eccezione — un job che solleva
  # ritenta tre volte e poi tace, e il silenzio qui sarebbe indistinguibile da «è andato tutto bene».
  class StagingProofJob < ApplicationJob
    queue_as :maintenance

    # Ogni riga costa due chiamate a GitHub: senza un tetto, un arretrato le farebbe partire tutte
    # insieme e il rate limit le farebbe fallire in blocco.
    BATCH = 25

    def perform(workflow_id = nil)
      workflows = workflow_id ? Agents::Workflow.where(id: workflow_id) : due_records

      # Il lotto è già limitato: find_each scarterebbe l'ordine di scadenza.
      workflows.each do |workflow|
        Agents::Staging::VerifyMerge.call(workflow:)
      rescue StandardError => e
        Rails.logger.error("Agents::StagingProofJob: #{workflow.id} #{e.class}: #{e.message}")
      end
    end

    private

    def due_records
      Agents::Workflow.where.not(closer_staging_completed_at: nil)
                      .where(closer_staging_verified_at: nil, cancelled_at: nil)
                      .where(closer_staging_next_check_at: ..Time.current)
                      .order(:closer_staging_next_check_at)
                      .limit(BATCH)
    end
  end
end
