# app/services/agents/skill_releases/pin.rb
# frozen_string_literal: true

module Agents
  module SkillReleases
    # Keeps an organization on one available version (CYRA-912). Older versions are allowed on
    # purpose: pinning back is a choice, not a regression.
    class Pin < ApplicationService
      def initialize(organization:, version:, actor:)
        @organization = organization
        @version = version.to_s.delete_prefix("v")
        @actor = actor
      end

      def call
        release = SkillRelease.available.find_by(version: @version)
        return refused if release.nil?

        pin = @organization.skill_release_pin || @organization.build_skill_release_pin
        pin.update!(skill_release: release, pinned_by_id: @actor&.id)
        Result.ok(pin)
      rescue ActiveRecord::RecordNotUnique
        @organization.reload
        retry
      end

      private

      def refused
        Result.err(AppError.new("cyi skill version #{@version} does not exist or is withdrawn", code: "R422-AGENT-010", status: :unprocessable_content))
      end
    end
  end
end
