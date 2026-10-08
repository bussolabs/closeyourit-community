# frozen_string_literal: true

module Cli
  module V1
    module Agents
      # Every recorded cyi skills version, newest first (CYRA-912). Read: agents.view or agents.manage.
      class SkillReleasesController < Cli::V1::BaseController
        include SkillReleaseAccess

        before_action :require_view

        def index
          releases = ::Agents::SkillRelease.all.sort_by(&:semver).reverse
          render_ok(releases.map do |release|
            { version: release.version, url: release.url, sha256: release.sha256,
              published_at: release.published_at, withdrawn: release.withdrawn? }
          end)
        end
      end
    end
  end
end
