# frozen_string_literal: true

module Api
  module V1
    module Leases
      class BaseController < Api::BaseController
        include AutomatorAuthentication

        before_action :authenticate_automator_host!

        private

        # profile_digest NON è permesso: è AUTORITATIVO server-side (Acquire lo deriva dal PhaseProfile),
        # mai iniettabile dal client. execution_phase è l'assertion della fase host-first (CYAU-96).
        def lease_params
          ActionController::Parameters.new(request.request_parameters)
                                      .permit(:ticket, :host_id, :run_id, :agent, :execution_phase, :ttl_seconds)
                                      .to_h.symbolize_keys
        end

        def render_lease(lease, status: :ok)
          render json: { data: AgentLeaseSerializer.new(lease).as_json }, status:
        end

        # Automator legge l'holder dalla radice data anche su 409; l'envelope error resta presente
        # con codice stabile per osservabilità e altri consumer.
        def render_lease_error(error)
          holder = error.details&.dig(:holder)
          return render_error(error.code, error.message, status: error.status, details: error.details) unless holder

          render json: {
            data: holder,
            error: { code: error.code, message: error.message, details: error.details }
          }, status: error.status
        end
      end
    end
  end
end
