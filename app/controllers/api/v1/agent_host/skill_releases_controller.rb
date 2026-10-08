# frozen_string_literal: true

module Api
  module V1
    module AgentHost
      # The cyi skills version this host's organization must run (CYRA-912), the same answer the CLI
      # gets. Host token cyi_ah_ only.
      class SkillReleasesController < Api::BaseController
        include AutomatorAuthentication

        before_action :authenticate_automator_host!

        def show
          result = ::Agents::SkillReleases::Resolve.call(organization: Current.organization)
          return render_ok(result.value) if result.ok?

          render_error(result.error.code, result.error.message, status: result.error.status)
        end
      end
    end
  end
end
