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
          return rework_from_conflict! if result_state == "blocked" && failure_category == "merge_conflict"
          return block_from_agent! if result_state == "blocked"
          return unless result_state == "staging-released"

          workflow.update!(closer_staging_completed_at: Time.current)
        end

        def failure_category = @payload.dig("result", "failure", "category")

        # CYRA-1069 — main moved and the approved branch no longer merges: the autopilot brings main in,
        # and the new head goes back to a person's review like any other delivery.
        def rework_from_conflict!
          workflow.update!(autopilot_started_at: nil, autopilot_completed_at: nil, autopilot_approved_at: nil,
                           autopilot_approved_by_id: nil, closer_staging_started_at: nil,
                           candidate_verified_at: nil, review_candidate_id: nil,
                           **Agents::Workflow.cleared_block)
        end
      end
    end
  end
end
