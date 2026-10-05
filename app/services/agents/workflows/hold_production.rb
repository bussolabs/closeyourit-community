# frozen_string_literal: true

module Agents
  module Workflows
    # «Ferma» un rilascio che aspetta la produzione (CYRA-871). Il codice è già su main, quindi il
    # blocco su closer_production tiene occupata la fila del repository (ProductionLock): nessun altro
    # rilascio lo porta in produzione. Si riparte con Unblock («Riprova»). Decide il CTO effettivo.
    class HoldProduction < ApplicationService
      include CtoGate
      include ConcludedTicketGate

      KIND = "held_by_person"

      def initialize(workflow:, actor:)
        @workflow = workflow
        @actor = actor
      end

      def call
        return forbidden unless authorized_cto?
        return concluded_ticket if concluded_ticket?

        ApplicationRecord.transaction do
          @workflow.lock!
          return not_waiting unless @workflow.ready_execution_phase == "closer_production"

          Block.call(workflow: @workflow, phase: "closer_production", kind: KIND,
                     reason: "#{KIND}: #{@actor.name}")
        end
        Result.ok(@workflow)
      end

      private

      def not_waiting
        Result.err(AppError.new("La lavorazione non sta aspettando la produzione",
                                code: "R409-WORKFLOW-015", status: :conflict))
      end
    end
  end
end
