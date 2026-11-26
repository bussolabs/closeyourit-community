# frozen_string_literal: true

module Agents
  # CYRA-1154 — asks GitHub whether the delivered proposals still merge after main moved. The push
  # enqueues it right away; the recurring round picks up the rows waiting for GitHub to compute.
  # One round at a time, under one key for the push and the recurring round alike, like
  # Agents::CandidateVerificationJob: pushes landing together do not stack calls. A round discarded here
  # loses nothing, the rows stay due for the next minute; Run's conditional writes cover a lease that expired.
  class ConflictCheckJob < ApplicationJob
    queue_as :maintenance
    limits_concurrency to: 1, key: "periodic", duration: 5.minutes, on_conflict: :discard

    # Each row costs a call to GitHub: a cap keeps a busy repository inside the rate limit. The rows past
    # the cap stay due, oldest first, and the round of the next minute takes them.
    BATCH = 50

    def perform
      due_records.each do |check|
        Agents::ConflictChecks::Run.call(check:)
      rescue StandardError => e
        # One row that fails must not take the rest of the batch with it.
        Rails.logger.error("Agents::ConflictCheckJob: #{check.id} #{e.class}: #{e.message}")
      end
    end

    private

    def due_records
      Agents::ConflictCheck.due.order(:next_check_at).limit(BATCH)
                           .includes(:workflow, delivery_candidate: { repository: :installation })
    end
  end
end
