# frozen_string_literal: true

module Api
  module V1
    module AgentHost
      # CYAU-235 — the supporter's proposed answers to one round. The server decides whether they stand:
      # see Agents::Supporters::AnswerRound. Host token (cyi_ah_) only.
      class SupporterAnswersController < Api::BaseController
        include AutomatorAuthentication

        before_action :authenticate_automator_host!
        before_action :require_certified_host!

        def create
          result = ::Agents::Supporters::AnswerRound.call(host: Current.agent_host, round_id: params[:supporter_round_id],
                                                          payload: params.to_unsafe_h.slice("digest", "answers"))
          if result.ok?
            render_ok(result.value)
          else
            render_error(result.error.code, result.error.message, status: result.error.status)
          end
        end

        private

        # Only a machine a person certified may answer for the organization.
        def require_certified_host!
          return if Current.agent_host.certified_at.present?

          render_error("R403-SUPPORTER-002", "Host is not certified: the supporter does not run", status: :forbidden)
        end
      end
    end
  end
end
