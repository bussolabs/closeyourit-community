# frozen_string_literal: true

module Api
  module V1
    module AgentHost
      # CYRA-1133 — the machine's proposals and votes for one council slice. The server decides what stands:
      # see Agents::Council::Settle. Host token (cyi_ah_) only.
      class CouncilResultsController < Api::BaseController
        include AutomatorAuthentication

        before_action :authenticate_automator_host!
        before_action :require_certified_host!

        def create
          result = ::Agents::Council::Settle.call(host: Current.agent_host, run_id: params[:council_slice_id],
                                                  payload: params.to_unsafe_h.slice("proposals", "critiques", "failure"))
          if result.ok?
            render_ok(result.value)
          else
            render_error(result.error.code, result.error.message, status: result.error.status)
          end
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
