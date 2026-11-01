# frozen_string_literal: true

require "rails_helper"

RSpec.describe Wikitech::ProcessPendingNotesJob do
  it "queues again the notes pending for more than an hour" do
    old = create(:wikitech_note, created_at: 2.hours.ago)
    create(:wikitech_note, created_at: 10.minutes.ago)
    create(:wikitech_note, created_at: 2.hours.ago, status: :processed)

    expect { described_class.perform_now }
      .to have_enqueued_job(Wikitech::ProcessNoteJob).with(note_id: old.id).exactly(:once)
  end

  it "does nothing while the AI switch is off" do
    create(:wikitech_note, created_at: 2.hours.ago)
    Settings::Global.instance.update!(ai_wikitech_enabled: false)

    expect { described_class.perform_now }.not_to have_enqueued_job(Wikitech::ProcessNoteJob)
  end
end
