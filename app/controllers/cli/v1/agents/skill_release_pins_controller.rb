# frozen_string_literal: true

module Cli
  module V1
    module Agents
      # The organization's pinned cyi skills version (CYRA-912): read with agents.view, change with
      # agents.manage (a dangerous key, so the CLI sends confirm=1).
      class SkillReleasePinsController < Cli::V1::BaseController
        include SkillReleaseAccess

        before_action :require_view, only: :show
        before_action -> { require_permission!("agents.manage") }, only: %i[update destroy]

        def show
          render_ok({ version: Current.organization.skill_release_pin&.skill_release&.version })
        end

        def update
          result = ::Agents::SkillReleases::Pin.call(organization: Current.organization, version: params[:version],
                                                     actor: Current.account)
          return render_ok({ version: result.value.skill_release.version }) if result.ok?

          render_error(result.error.code, result.error.message, status: result.error.status)
        end

        def destroy
          ::Agents::SkillReleases::Unpin.call(organization: Current.organization)
          render_ok({ version: nil })
        end
      end
    end
  end
end
