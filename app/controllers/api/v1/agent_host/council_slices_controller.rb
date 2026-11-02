# frozen_string_literal: true

module Api
  module V1
    module AgentHost
      # CYRA-1133 — the next council slice this machine should run, or 204 when none. Certified hosts only.
      class CouncilSlicesController < Api::BaseController
        include AutomatorAuthentication

        before_action :authenticate_automator_host!
        before_action :require_certified_host!

        def show
          item = ::Agents::Council::NextSlice.call(host: Current.agent_host).value
          item ? render_ok(item) : head(:no_content)
        end

        private

        # Only a machine a person certified may run the council for the organization.
        def require_certified_host!
          return if Current.agent_host.certified_at.present?

          render_error("R403-COUNCIL-002", "Host is not certified: the council does not run", status: :forbidden)
        end
      end
    end
  end
end
