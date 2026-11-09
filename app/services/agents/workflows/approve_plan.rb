# frozen_string_literal: true

module Agents
  module Workflows
    class ApprovePlan < ApplicationService
      include CtoGate
      include ConcludedTicketGate

      def initialize(workflow:, actor:)
        @workflow = workflow
        @actor = actor
      end

      def call
        return missing_cto if effective_cto.blank?
        return concluded_ticket if concluded_ticket?
        return forbidden unless authorized_cto?

        ApplicationRecord.transaction do
          @workflow.lock!
          plan = @workflow.plans.reorder(version: :desc).lock.first!
          return stale unless @workflow.planned_at? && plan.approved_at.nil? && plan.change_request.blank?

          now = Time.current
          # CYRA-610 — approvare il piano è il momento in cui due cose vengono fissate e non cambiano
          # più: su quale archivio può nascere il lavoro, e qual è la prova che dirà «fatto». Prima non
          # si fissava niente: l'archivio veniva riletto a ogni presa in carico (se qualcuno cambiava il
          # collegamento nel frattempo, il lavoro nasceva altrove senza che nessuno se ne accorgesse) e
          # la prova la sceglieva chi esegue, alla fine, quando ormai era tardi per discuterne.
          #
          # Un dato mancante NON fa fallire l'approvazione. Fermare il lavoro alla porta d'ingresso
          # perché manca un dato che serve alla porta d'uscita non aggiunge sicurezza: toglie l'unica
          # strada. Le due colonne restano nulle insieme — il vincolo di database le vuole entrambe o
          # nessuna — e alla fine sarà una persona a dire «fatto» invece della macchina.
          # Decidere sul piano è anche decidere sul blocco (CYRA-218): sopravvivendo all'approvazione
          # terrebbe fuori dalla coda un workflow con un piano approvato, fermo senza che nulla lo dica.
          # QUALE versione del piano è quella approvata si fissa sempre, anche quando le due decisioni
          # non erano componibili: è l'identità di ciò che è stato approvato, e non dipende da come è
          # configurato il progetto. Chi eseguirà dovrà dichiarare di lavorare su QUESTA.
          FreezePlan.call(workflow: @workflow, plan:, actor: @actor, now:)
          # CYRA-1152 — an epic's split creates its children instead of moving on to writing code.
          SplitEpic.call(workflow: @workflow, plan:, actor: @actor, now:) if plan.split?
        end
        Result.ok(@workflow)
      rescue ActiveRecord::RecordNotFound
        stale
      rescue SplitEpic::Failed => e
        Result.err(e.error)
      end

      private

      def missing_cto
        Result.err(AppError.new("CTO non configurato", code: "R409-WORKFLOW-002", status: :conflict))
      end

      def stale
        Result.err(AppError.new("La versione del piano non è più approvabile",
                                code: "R409-WORKFLOW-001", status: :conflict))
      end
    end
  end
end
