# app/services/agents/skill_releases/resolve.rb
# frozen_string_literal: true

module Agents
  module SkillReleases
    # The one answer CLI and automator share (CYRA-912): the pinned version when it is still
    # available, otherwise the latest available one. A withdrawn pin is reported, not hidden.
    class Resolve < ApplicationService
      def initialize(organization:)
        @organization = organization
      end

      def call
        pin = @organization.skill_release_pin
        pinned = pin&.skill_release
        release = pinned && !pinned.withdrawn? ? pinned : SkillRelease.latest_available
        return none if release.nil?

        Result.ok(
          version: release.version, url: release.url, sha256: release.sha256, git_sha: release.git_sha,
          pinned: pin.present?, pinned_version: pinned&.version, pin_withdrawn: pinned&.withdrawn? || false
        )
      end

      private

      def none
        Result.err(AppError.new("No cyi skill version available", code: "R404-AGENT-009", status: :not_found))
      end
    end
  end
end
