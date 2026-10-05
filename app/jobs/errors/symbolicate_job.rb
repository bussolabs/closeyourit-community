# frozen_string_literal: true

module Errors
  class SymbolicateJob < ApplicationJob
    queue_as :ingest
    retry_on ::Artifacts::Unavailable, wait: :polynomially_longer, attempts: 5

    def perform(project_id:, event_id:, event_created_at:)
      project = Projects::Project.find_by(id: project_id)
      return unless project
      event = project.error_events.find_by(id: event_id, created_at: event_created_at)
      Symbolication::Record.call(event: event) if event
    rescue ActiveRecord::RecordNotFound
      Rails.logger.debug("Symbolication owner disappeared during processing")
    end
  end
end
