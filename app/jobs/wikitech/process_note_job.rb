# frozen_string_literal: true

module Wikitech
  # Turns one pending note into cards (CYRA-1129). Low-priority `ai` lane: a channel history can
  # queue thousands of notes, and none of them is refused, they only wait their turn.
  class ProcessNoteJob < ApplicationJob
    queue_as :ai

    # The same note never runs twice at once: two runs would read the same text and race on its cards.
    limits_concurrency to: 1, key: ->(note_id:) { "wikitech:note:#{note_id}" }

    # The home AI server that does not answer is not back in ten seconds: wait minutes.
    retry_on TransientFailure,
             wait: ->(executions) { (executions**2).minutes + rand(0..59).seconds },
             attempts: MAX_ATTEMPTS do |job, error|
      Wikitech::Note.where(id: job.arguments.first[:note_id]).update_all(last_error: (error.try(:code) || error.class.name).to_s.first(255))
    end

    def perform(note_id:)
      note = Wikitech::Note.find_by(id: note_id)
      return unless note&.status_pending?
      # Switched off by the god: the note stays pending and Wikitech::ProcessPendingNotesJob resumes it.
      return if Ai::Feature.disabled?(:wikitech)

      Current.organization = note.organization # runs with this organization's AI settings (CYRA-914)
      result = Wikitech::ExtractEntries.call(note: note)
      raise result.error if result.err?

      entries = result.value.map { |item| Wikitech::MergeItem.call(note: note, item: item).value }
      note.update!(status: entries.any? ? :processed : :discarded, processed_at: Time.current, last_error: nil)
      entries.uniq.each { |entry| follow_up(entry) }
    end

    private

    def follow_up(entry)
      Wikitech::VerifyRepoJob.perform_later(entry_id: entry.id) if entry.repo_url && entry.repo_checked_at.nil?
      Wikitech::EmbedEntryJob.perform_later(entry_id: entry.id)
    end
  end
end
