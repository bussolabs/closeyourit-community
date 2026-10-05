# frozen_string_literal: true

module Api
  module V1
    module Agents
      # Deferral della coda host-scoped (CYAU-84): appiattito, senza agent_id nell'URL. Il deferral è keyed su
      # host+ticket+execution_phase, la selezione firmata è host-bound.
      class TicketQueueDeferralsController < Api::BaseController
        include AutomatorAuthentication

        before_action :authenticate_automator_host!

        def create
          payload = deferral_params
          result = ::Agents::TicketQueues::Defer.call(
            organization: Current.organization,
            host: Current.agent_host,
            selection_token: payload.delete(:selection_token),
            params: payload
          )
          if result.err?
            return render_error(
              result.error.code, result.error.message, status: result.error.status, details: result.error.details
            )
          end

          outcome = result.value
          data = AgentTicketQueueDeferralSerializer.new(outcome.deferral).as_json.merge(replayed: outcome.replayed)
          render json: { data: }, status: outcome.replayed ? :ok : :created
        end

        private

        def deferral_params
          ActionController::Parameters.new(request.request_parameters)
                                      .permit(:selection_token, :host_id, :reason)
                                      .to_h.symbolize_keys
        end
      end
    end
  end
end
