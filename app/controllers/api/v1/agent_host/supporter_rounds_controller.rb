# frozen_string_literal: true

module Api
  module V1
    module AgentHost
      # CYAU-235 — the next clarification round the machine's supporter should answer, or 204 when none.
      # Host token (cyi_ah_) only, certified host only.
      class SupporterRoundsController < Api::BaseController
        include AutomatorAuthentication

        before_action :authenticate_automator_host!
        before_action :require_certified_host!

        def show
          item = ::Agents::Supporters::NextRound.call(host: Current.agent_host).value
          item ? render_ok(item) : head(:no_content)
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
