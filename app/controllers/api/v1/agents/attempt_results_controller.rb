# frozen_string_literal: true

module Api
  module V1
    module Agents
      class AttemptResultsController < Api::BaseController
        include AutomatorAuthentication

        before_action :authenticate_automator_host!

        def update
          attempt = ::Agents::Attempt.where(organization: Current.organization).find(params[:agent_attempt_id])
          result = ::Agents::Attempts::Deliver.call(
            organization: Current.organization, host: Current.agent_host, attempt:, payload: result_params
          )
          return render_error(result.error.code, result.error.message,
                              status: result.error.status, details: result.error.details) if result.err?

          render_ok(AgentAttemptSerializer.new(result.value))
        rescue ActiveRecord::RecordNotFound
          render_error("R404-ATTEMPT-001", "Tentativo non trovato", status: :not_found)
        end

        private

        def result_params
          # CYAU-178: `observed` è ciò che l'host ha MISURATO sulla propria copia di lavoro, non ciò
          # che l'agente dichiara. Permesso come chiave annidata; QUALI fasi devono portarlo lo decide
          # Attempts::Deliver, l'unico che conosce la fase reclamata.
          params.permit(:runtime, :reviewer_runtime, :cost_usd, :model, result: {}, review: {}, observed: {}).to_h
        end
      end
    end
  end
end
