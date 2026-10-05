# frozen_string_literal: true

module Api
  module V1
    module Agents
      # Canale del fallimento (CYRA-282): l'automator riporta che la lavorazione è morta sulla macchina, col
      # motivo. Gemello di AttemptResultsController (l'esito riuscito/bocciato) ma per il guasto tecnico —
      # marca `failed` invece di attraversare la revisione incrociata. Token host cyi_ah_ come tutti i report.
      class AttemptFailuresController < Api::BaseController
        include AutomatorAuthentication

        before_action :authenticate_automator_host!

        def create
          attempt = ::Agents::Attempt.where(organization: Current.organization).find(params[:agent_attempt_id])
          result = ::Agents::Attempts::ReportFailure.call(
            host: Current.agent_host, attempt:, reason: params[:reason]
          )
          return render_error(result.error.code, result.error.message,
                              status: result.error.status, details: result.error.details) if result.err?

          render_ok(AgentAttemptSerializer.new(result.value))
        rescue ActiveRecord::RecordNotFound
          render_error("R404-ATTEMPT-001", "Tentativo non trovato", status: :not_found)
        end
      end
    end
  end
end
