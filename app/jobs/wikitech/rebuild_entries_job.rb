# frozen_string_literal: true

module Wikitech
  # Rewrites an organization's cards after its AI answer language changed: cards are stored AI text,
  # so they keep the old language until the AI reads their notes again. Discarded notes had nothing
  # technical in any language and stay discarded.
  class RebuildEntriesJob < ApplicationJob
    queue_as :batch

    def perform(organization_id:)
      organization = Organizations::Organization.find_by(id: organization_id)
      return unless organization

      notes = organization.wikitech_notes.status_processed
      note_ids = notes.pluck(:id)
      ActiveRecord::Base.transaction do
        organization.wikitech_entries.destroy_all
        notes.where(id: note_ids).update_all(status: Wikitech::Note.statuses[:pending], processed_at: nil)
      end
      note_ids.each { |note_id| Wikitech::ProcessNoteJob.perform_later(note_id: note_id) }
    end
  end
end
