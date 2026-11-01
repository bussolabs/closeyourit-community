# frozen_string_literal: true

module Wikitech
  # Hourly: queues again the notes still pending after an hour — the AI switch was off, or the home
  # AI server stayed down past the retries. A note that keeps failing is tried again every hour.
  class ProcessPendingNotesJob < ApplicationJob
    queue_as :batch

    def perform
      return if Ai::Feature.disabled?(:wikitech)

      Wikitech::Note.status_pending.where(created_at: ...1.hour.ago).in_batches do |batch|
        batch.pluck(:id).each { |note_id| Wikitech::ProcessNoteJob.perform_later(note_id: note_id) }
      end
    end
  end
end
