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
      request_production_approvals unless workflow_id
    end

    private

    # CYRA-1278 — a switch turned on after the staging check still stops the releases already waiting.
    def request_production_approvals
      Agents::Workflows::RequestProductionApproval.for_projects(Projects::Project.production_approval_required_active)
      # CYRA-1302 — the same for the plans that declare a proof in a browser.
      Agents::Workflows::RequestProductionApproval.for_projects(Projects::Project.browser_proof_go_ahead)
      # CYAU-329 — and for the projects whose Tester is on, where no machine has the browser to run that proof.
      Agents::Workflows::RequestProductionApproval.for_projects(Projects::Project.tester_on)
    rescue StandardError => e
      Rails.logger.error("Agents::StagingProofJob: production approvals #{e.class}: #{e.message}")
    end

    def due_records
      Agents::Workflow.where.not(closer_staging_completed_at: nil)
                      .where(closer_staging_verified_at: nil, cancelled_at: nil)
                      .where(closer_staging_next_check_at: ..Time.current)
                      .order(:closer_staging_next_check_at)
                      .limit(BATCH)
    end
  end
end
