# frozen_string_literal: true

module Agents
  module Workflows
    # CYRA-675 — «Rivaluta»: rimanda la lavorazione alla pianificazione perché rilegga il codice di
    # OGGI e risponda alla domanda che prima non si poteva fare — questa cosa serve ancora, o nel
    # frattempo è già stata fatta?
    #
    # Non è un terzo modo di sbloccare. Unblock riapre la fase ferma e la fa riprovare com'era;
    # RequestPlanChanges rifà il piano ma pretende che un piano esista e vuole una motivazione. Qui
    # non c'è niente da rimproverare a nessuno: si chiede di guardare di nuovo, e la lavorazione può
    # non aver mai prodotto un piano.
    #
    # La risposta «è già fatto» non arriva da qui: la dà chi pianifica, come esito `already-done` del
    # contratto, e la applica Agents::Attempts::Deliver. Questo servizio fa una cosa sola — rimettere
    # la pianificazione in condizione di essere reclamata.
    #
    #   Agents::Workflows::Reassess.call(workflow:, actor:) → Result
    class Reassess < ApplicationService
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
          # Il gate si rilegge SOTTO LOCK, non solo dove si disegna il pulsante: fra la pagina aperta e
          # il click la lavorazione può essere andata avanti, e azzerare `approved_at` su una macchina
          # che sta già scrivendo codice lascerebbe uno stato che nessuno ha voluto.
          return not_reassessable unless @workflow.reassessable?

          # Ferma sul triage: lì `triaged_at` è nil e azzerare la pianificazione non basta, perché il
          # claim ha già scritto `triage_started_at` e la coda continua a saltarla (CYRA-267). Sul
          # planner non serve: non ha un avvio dedicato, quindi torna reclamabile da sé.
          stopped = @workflow.stopped_execution_phase
          @workflow.reopen_execution_phase!(stopped) if stopped

          # Il piano già scritto torna da fare. La versione vecchia resta in archivio: `planned_at` è
          # il marcatore di conclusione della fase, non il piano, e il planner ne produrrà una nuova.
          # `approved_at` si azzera insieme perché sono lo stesso gesto letto due volte — un piano non
          # più valido non può restare approvato — e il blocco se ne va, o la fase riaperta non
          # verrebbe più offerta a nessun host (CYRA-218).
          @workflow.update!(planned_at: nil, approved_at: nil, approved_by: nil,
                            **Agents::Workflow.cleared_block)
        end
        Result.ok(@workflow.reload)
      end

      private

      def terminal
        Result.err(AppError.new("La lavorazione è chiusa e non può ripartire",
                                code: "R409-WORKFLOW-001", status: :conflict))
      end

      def not_reassessable
        Result.err(AppError.new(I18n.t("member.home.actions.not_reassessable"),
                                code: "R409-WORKFLOW-014", status: :conflict))
      end
    end
  end
end
