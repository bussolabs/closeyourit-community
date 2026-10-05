# frozen_string_literal: true

module Api
  module V1
    module Agents
      # Mutazione dedicata della coda host-scoped (CYAU-84): appiattita, senza agent_id nell'URL. Il ticket e
      # la fase non arrivano dal client, ma dalla selezione server-side firmata host-bound. POST /leases resta
      # il contratto legacy indipendente.
      class TicketQueueClaimsController < Api::V1::Leases::BaseController
        def create
          payload = claim_params
          result = ::Agents::TicketQueues::Claim.call(
            organization: Current.organization,
            host: Current.agent_host,
            selection_token: payload.delete(:selection_token),
            params: payload
          )
          return render_lease_error(result.error) if result.err?

          outcome = result.value
          data = AgentLeaseSerializer.new(outcome.lease).as_json.merge(
            "attempt_id" => outcome.attempt.id, "review_mode" => outcome.attempt.host.review_mode,
            "work_engine" => outcome.attempt.runtime
          )
          render json: { data: }, status: outcome.fresh_acquisition ? :created : :ok
        end

        private

        def claim_params
          ActionController::Parameters.new(request.request_parameters)
                                      .permit(:selection_token, :host_id, :run_id, :ttl_seconds)
                                      .to_h.symbolize_keys
        end
      end
    end
  end
end
