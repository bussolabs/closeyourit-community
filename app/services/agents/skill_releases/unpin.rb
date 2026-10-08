# app/services/agents/skill_releases/unpin.rb
# frozen_string_literal: true

module Agents
  module SkillReleases
    # Back to following the latest available version (CYRA-912). Idempotent.
    class Unpin < ApplicationService
      def initialize(organization:)
        @organization = organization
      end

      def call
        @organization.skill_release_pin&.destroy!
        Result.ok(nil)
      end
    end
  end
end
