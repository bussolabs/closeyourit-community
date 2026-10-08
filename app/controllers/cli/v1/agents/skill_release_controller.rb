# frozen_string_literal: true

module Cli
  module V1
    module Agents
      # The cyi skills version this organization must install (CYRA-912). Read: agents.view or agents.manage.
      class SkillReleaseController < Cli::V1::BaseController
        include SkillReleaseAccess

        before_action :require_view

        def show
          result = ::Agents::SkillReleases::Resolve.call(organization: Current.organization)
          return render_ok(result.value) if result.ok?

          render_error(result.error.code, result.error.message, status: result.error.status)
        end
      end
    end
  end
end
