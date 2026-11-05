# frozen_string_literal: true

module Agents
  # Closes approved work that a later proved production release already carries (CloseAlreadyReleased).
  class AlreadyReleasedSweepJob < ApplicationJob
    queue_as :maintenance

    def perform
      Agents::Workflow.where(cancelled_at: nil, completed_at: nil).where.not(autopilot_approved_at: nil)
                      .where.not(review_candidate_id: nil).find_each do |workflow|
        Agents::Workflows::CloseAlreadyReleased.call(workflow:)
      rescue StandardError => e
        Rails.logger.error("Agents::AlreadyReleasedSweepJob: #{workflow.id} #{e.class}: #{e.message}")
      end
    end
  end
end
