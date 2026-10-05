# frozen_string_literal: true

module Agents
  module Workflows
    # Rimette in coda una lavorazione fermata dal tetto ai tentativi di revisione (CYRA-218).
    #
    # Serve perché il blocco scatta proprio dove NON c'è ancora niente da approvare: una fase bocciata non
    # produce effetti, quindi un planner bocciato due volte non ha creato nessun Agents::Plan e sia
    # ApprovePlan sia RequestPlanChanges falliscono con `stale` (cercano l'ultima versione del piano, che
    # non esiste). Senza questa via d'uscita l'unica azione possibile su una lavorazione ferma sarebbe
    # annullarla — buttando via anche il triage già fatto.
    #
    # Decide il CTO effettivo, come per il piano: è la stessa decisione ("questa lavorazione va avanti"),
    # presa un passo prima.
    #
    # CYRA-267: rimette in coda per davvero. Azzerare blocked_at basta solo se la fase bocciata è il planner
    # (l'unica senza un avvio proprio); per tutte le altre il claim ha già scritto <fase>_started_at e la
    # coda continuerebbe a saltarle — il pulsante sembrava funzionare e la lavorazione restava ferma.
    class Unblock < ApplicationService
      include CtoGate
      include ConcludedTicketGate

      def initialize(workflow:, actor:)
        @workflow = workflow
        @actor = actor
      end

      def call
        return forbidden unless authorized_cto?
        return concluded_ticket if concluded_ticket?

        ApplicationRecord.transaction do
          @workflow.lock!
          return terminal if @workflow.terminal?

          # CYRA-598 — quando a fermare è stata la macchina, la fase da riaprire è quella SCRITTA NEL
          # BLOCCO, non quella dedotta dagli attempt. La regola sta su Agents::Workflow
          # (#stopped_execution_phase) perché la legge anche #reassessable?: due copie divergono.
          stalled = @workflow.stopped_execution_phase
          rearm = @workflow.blocked_kind == "candidate_check"
          # Non è un errore sbloccare ciò che non è bloccato: due click ravvicinati sono la stessa
          # decisione presa una volta, non un conflitto da mostrare a chi l'ha presa.
          @workflow.update!(**Agents::Workflow.cleared_block) if @workflow.blocked_at?
          # Togliere il blocco NON rimette in coda niente (CYRA-267): la fase bocciata era stata claimata e
          # il suo <fase>_started_at è ancora scritto, quindi la coda continua a saltarla. Va riaperta come
          # fa il recovery degli orfani — è la stessa fase interrotta, con un'altra causa.
          @workflow.reload if stalled && @workflow.reopen_execution_phase!(stalled)
          rearm_candidate! if rearm
        end
        Result.ok(@workflow)
      end

      private

      # CYRA-761 — un blocco del controllo della proposta lascia il candidato «rifiutato», che non è
      # fra gli stati ritentabili e non ha un prossimo controllo: togliere il cartello senza riarmarlo
      # vuol dire una scheda che dice «va avanti da sola» mentre nessuno torna a guardare.
      #
      # Una riga già verificata è la prova di cosa è stato approvato e non si riscrive: in quel caso
      # se ne apre una nuova sulla stessa proposta (senza `head_sha`, come alla consegna), e sarà il
      # prossimo giro a congelarle il codice letto.
      def rearm_candidate!
        latest = @workflow.delivery_candidates.order(:created_at).last
        return if latest.nil?

        row = @workflow.delivery_candidates.find_or_create_by!(
          repository_full_name: latest.repository_full_name, number: latest.number, head_sha: nil
        ) do |candidate|
          candidate.attempt = latest.attempt
          candidate.repository = latest.repository
        end
        row.update!(state: :pending, next_check_at: Time.current, last_error_code: nil,
                     repository: row.repository || linked_repository(row.repository_full_name))
      end

      # Un candidato rifiutato per `repository_not_linked` non ha un repository: se nel frattempo
      # qualcuno l'ha collegato, riarmarlo senza risolverlo lo farebbe rifiutare di nuovo per lo
      # stesso motivo. Stessa risoluzione della consegna (Agents::Attempts::Deliver).
      def linked_repository(full_name)
        Github::Repository.joins(project: :organization)
                          .find_by(full_name:, projects: { organization_id: @workflow.organization.id })
      end

      def terminal
        Result.err(AppError.new("La lavorazione è chiusa e non può ripartire",
                                code: "R409-WORKFLOW-001", status: :conflict))
      end
    end
  end
end
