# frozen_string_literal: true

module Api
  module V1
    module Agents
      # Risorsa di lettura della coda preflight host-scoped (CYAU-84): appiattita, senza agent_id nell'URL.
      # Restituisce al massimo un candidato e non lo reclama: la mutua esclusione resta responsabilità
      # dell'endpoint leases dopo il preflight del daemon.
      class TicketQueuesController < Api::BaseController
        include AutomatorAuthentication

        before_action :authenticate_automator_host!

        def show
          result = ::Agents::TicketQueues::Next.call(
            organization: Current.organization,
            project_key: params[:project_key],
            host: Current.agent_host
          )
          return render_error(result.error.code, result.error.message, status: result.error.status) if result.err?

          candidate = result.value
          return render_ok(nil) unless candidate

          execution_phase = candidate.agent_workflow&.ready_execution_phase
          return render_ok(nil) unless execution_phase

          data = AgentTicketCandidateSerializer.new(candidate).as_json
          estimated_cost = ::Agents::TicketQueues::Selection.estimated_cost_for(ticket: candidate)
          data["estimated_cost"] = estimated_cost
          data["selection_token"] = ::Agents::TicketQueues::Selection.issue(
            ticket: candidate, host: Current.agent_host, execution_phase:, estimated_cost:
          )
          render_ok(data)
        end
      end
    end
  end
end
