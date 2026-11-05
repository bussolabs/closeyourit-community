# frozen_string_literal: true

module Api
  module V1
    module AgentHost
      # CYRA-1197 — the supporter's verdict on one stopped workflow. The server decides whether it retries, stays
      # with a person or stops for safety: see Agents::Supporters::JudgeConsult.
      # Host token (cyi_ah_) only, certified host only.
      class SupporterConsultVerdictsController < Api::BaseController
        include AutomatorAuthentication

        before_action :authenticate_automator_host!
        before_action :require_certified_host!

        def create
          result = ::Agents::Supporters::JudgeConsult.call(host: Current.agent_host,
                                                           workflow_id: params[:supporter_consult_id],
                                                           payload: params.to_unsafe_h.slice("digest", "verdict"))
          if result.ok?
            render_ok(result.value)
          else
            render_error(result.error.code, result.error.message, status: result.error.status)
          end
        end

        private

        # Only a machine a person certified may judge for the organization.
        def require_certified_host!
          return if Current.agent_host.certified_at.present?

          render_error("R403-SUPPORTER-002", "Host is not certified: the supporter does not run", status: :forbidden)
        end
      end
    end
  end
end
