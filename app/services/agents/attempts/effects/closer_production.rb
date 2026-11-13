# frozen_string_literal: true

module Agents
  module Attempts
    module Effects
      # CYRA-624 — la consegna del closer di produzione NON chiude più il lavoro.
      #
      # Prima scriveva `completed_at` e portava il ticket a «Fatto» nell'istante in cui la macchina
      # diceva di aver messo l'etichetta della versione. Lì non era ancora stato rilasciato niente: il
      # rilascio parte dopo, e può andare male un minuto dopo — e il ticket restava «Fatto» lo stesso,
      # senza che nessuno venisse avvisato. È la promessa dichiarata e non mantenuta che si trova
      # dappertutto: si afferma una cosa e se ne controlla una più debole.
      #
      # Qui si scrive solo che LA FASE è finita, e si aggancia la prova. Il lavoro è finito quando il
      # sistema ha VISTO il rilascio in piedi (`Agents::Probes::Observe`).
      #
      # Il marcatore serve anche a un'altra cosa: senza, una fase di produzione già consegnata risulta
      # riapribile da chi recupera le fasi morte — e riaprirla qui vuol dire un SECONDO rilascio.
      class CloserProduction < Base
        # Board realtime alla consegna (parità con ApproveReview → done): il ticket appare Resolved
        # sulla board senza attendere un reload. Post-commit, come per il piano.
        #
        # CYRA-624 — si va a guardare subito, senza aspettare il giro del minuto: il rilascio può
        # essere già in piedi quando la consegna arriva.
        def after_commit
          Agents::ReleaseProbeJob.perform_later(attempt.workflow_id)
        end

        private

        def apply!
          return block_from_agent! if result_state == "blocked"
          return unless result_state == "production-released"

          workflow.update!(closer_production_completed_at: Time.current)
          # CYAU-329 — the ticket says whether the browser proofs of the plan ran on staging before this tag.
          Agents::Tester::ReleaseRecord.call(workflow:, block: payload["tester"], commit: payload.dig("result", "commit"))
          # CYRA-1193 — with the merge as proof of done there is nothing to observe: the stable
          # release is the last step, so the work is done here.
          return complete_on_merge! if merge_is_the_proof?

          bound = Agents::Probes::Bind.call(workflow:)
          # Un progetto che non dichiara come si prova che un rilascio è vivo non deve far aspettare
          # un'ora per niente: si chiama subito una persona, con parole diverse da quelle della scadenza.
          return if bound.ok?
          # The frozen proof cannot be armed, but the project has since declared the merge as its proof:
          # the stable release just delivered is that proof, so the work is done.
          return complete_on_merge! if project_declares_merge?

          Agents::Workflows::BlockExhaustedPhase.call(
            workflow:, phase: "closer_production", source: "release_probe",
            kind: "release_probe", reason: bound.error.message
          )
        end

        def merge_is_the_proof?
          workflow.frozen_plan&.completion_probe&.dig("kind") == "merge"
        end

        def project_declares_merge?
          workflow.ticket.project.github_repository&.release_probe_merge? || false
        end

        # Same writes as a closed production probe. The prerequisites gate in ChangeStatus has the last
        # word: if it refuses, the ticket keeps its status and the work stays open for a person.
        def complete_on_merge!
          state = workflow.organization.ticket_statuses.active.category_done.ordered.first
          return if state.nil?

          workflow.update!(completed_at: Time.current)
          outcome = Ticketing::ChangeStatus.call(organization: workflow.organization, ticket: workflow.ticket,
                                               status_id: state.id, channel: :workflow)
          workflow.update!(completed_at: nil) unless outcome.ok?
        end
      end
    end
  end
end
