# frozen_string_literal: true

module Agents
  module Attempts
    module Effects
      # closer_staging consegnato: sblocca closer_production (closer_staging_completed_at). Il ticket
      # resta nell'in_progress dove l'approvazione autopilot l'ha lasciato (la coda può ancora pescarlo).
      class CloserStaging < Base
        # CYRA-620 — la prova che il codice approvato è atterrato si va a guardare subito dopo il
        # commit, non dentro la transazione: dentro terrebbe righe bloccate per la durata di due
        # chiamate a GitHub.
        def after_commit
          Agents::StagingProofJob.perform_later(attempt.workflow_id)
        end

        private

        def apply!
          return block_from_agent! if result_state == "blocked"
          return unless result_state == "staging-released"

          workflow.update!(closer_staging_completed_at: Time.current)
        end
      end
    end
  end
end
