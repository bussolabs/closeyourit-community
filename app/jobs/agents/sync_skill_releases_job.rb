# frozen_string_literal: true

module Agents
  # Reads the public cyi skill releases every hour (CYRA-912). A failed read keeps the list as it is.
  class SyncSkillReleasesJob < ApplicationJob
    queue_as :maintenance

    def perform
      SkillReleases::Sync.call
    end
  end
end
