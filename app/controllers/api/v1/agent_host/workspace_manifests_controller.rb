# frozen_string_literal: true

module Api
  module V1
    module AgentHost
      # Serve all'Agent Host la struttura dei repository da clonare (contratto OneClick). Richiede il
      # token host cyi_ah_: un token organization cyi_a_ (solo bootstrap) non è ammesso.
      class WorkspaceManifestsController < Api::BaseController
        include AutomatorAuthentication

        before_action :authenticate_automator_host!

        def show
          render_ok(::Agents::Hosts::WorkspaceManifest.call(host: Current.agent_host).value)
        end
      end
    end
  end
end
