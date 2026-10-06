# frozen_string_literal: true

module Agents
  # CYRA-1034 — once a day, the latest releases of the programs the machines report.
  class RefreshRuntimeVersionsJob < ApplicationJob
    queue_as :maintenance

    def perform = Agents::RuntimeVersions.refresh!
  end
end
