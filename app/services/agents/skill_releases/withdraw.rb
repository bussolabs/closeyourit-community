# app/services/agents/skill_releases/withdraw.rb
# frozen_string_literal: true

module Agents
  module SkillReleases
    # Takes a faulty version out of resolution, or puts it back (CYRA-912). Platform action: only a god
    # reaches it, from Valhalla.
    class Withdraw < ApplicationService
      def initialize(release:, actor:, withdrawn: true)
        @release = release
        @actor = actor
        @withdrawn = withdrawn
      end

      def call
        if @withdrawn
          @release.update!(withdrawn_at: Time.current, withdrawn_by_id: @actor.id)
        else
          @release.update!(withdrawn_at: nil, withdrawn_by_id: nil)
        end
        Result.ok(@release)
      end
    end
  end
end
