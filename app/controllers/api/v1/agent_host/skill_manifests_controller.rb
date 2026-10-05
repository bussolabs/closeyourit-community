# frozen_string_literal: true

module Api
  module V1
    module AgentHost
      # Serve all'Agent Host il bundle skill versionato pinnato per l'org (repo/ref/version/digest). Richiede il
      # token host cyi_ah_ (un token organization cyi_a_ non è ammesso). Nessun bundle pinnato → 404: l'host
      # resta in prompt-mode (additivo, non rompe la pipeline CYRA-132).
      class SkillManifestsController < Api::BaseController
        include AutomatorAuthentication

        before_action :authenticate_automator_host!

        def show
          result = ::Agents::Hosts::SkillManifest.call(organization: Current.organization)
          if result.ok?
            render_ok(result.value)
          else
            render_error(result.error.code, result.error.message, status: result.error.status)
          end
        end
      end
    end
  end
end
