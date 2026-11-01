# frozen_string_literal: true

require "rails_helper"

RSpec.describe Wikitech::RebuildEntriesJob do
  let(:organization) { create(:organization) }

  it "drops the cards and queues their notes again, so the AI writes them in the new language" do
    note = create(:wikitech_note, organization:, status: :processed, processed_at: 1.day.ago)
    create(:wikitech_source, entry: create(:wikitech_entry, organization:), note:)

    expect { described_class.perform_now(organization_id: organization.id) }
      .to have_enqueued_job(Wikitech::ProcessNoteJob).with(note_id: note.id)
    expect(Wikitech::Entry.where(organization:)).to be_empty
    expect(note.reload).to have_attributes(status: "pending", processed_at: nil)
  end

  it "leaves the discarded notes and the other organizations alone" do
    discarded = create(:wikitech_note, organization:, status: :discarded)
    other_entry = create(:wikitech_entry)

    expect { described_class.perform_now(organization_id: organization.id) }
      .not_to have_enqueued_job(Wikitech::ProcessNoteJob)
    expect(discarded.reload).to be_status_discarded
    expect(Wikitech::Entry.exists?(other_entry.id)).to be(true)
  end
end
