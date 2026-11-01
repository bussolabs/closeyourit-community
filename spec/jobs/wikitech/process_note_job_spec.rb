# frozen_string_literal: true

require "rails_helper"

RSpec.describe Wikitech::ProcessNoteJob do
  let(:note) { create(:wikitech_note) }
  let(:godot) do
    Wikitech::ExtractEntries::Item.new(name: "Godot", repo_url: "https://github.com/godotengine/godot", summary: "Engine.",
                                       facts: [], categories: [], links: [], quote: nil)
  end

  it "runs on the low-priority AI lane" do
    expect(described_class.new.queue_name).to eq("ai")
  end

  it "turns the note into cards and queues verification and embedding" do
    allow(Wikitech::ExtractEntries).to receive(:call).and_return(Result.ok([ godot ]))

    expect { described_class.perform_now(note_id: note.id) }
      .to have_enqueued_job(Wikitech::VerifyRepoJob).and have_enqueued_job(Wikitech::EmbedEntryJob)

    expect(note.reload).to be_status_processed
    expect(note.processed_at).to be_present
    expect(note.entries.map(&:name)).to eq([ "Godot" ])
  end

  it "does not verify again a repository already checked" do
    create(:wikitech_entry, organization: note.organization, name: "Godot", repo_url: godot.repo_url, repo_checked_at: 1.day.ago)
    allow(Wikitech::ExtractEntries).to receive(:call).and_return(Result.ok([ godot ]))

    expect { described_class.perform_now(note_id: note.id) }.not_to have_enqueued_job(Wikitech::VerifyRepoJob)
  end

  it "discards a note with nothing technical" do
    allow(Wikitech::ExtractEntries).to receive(:call).and_return(Result.ok([]))

    described_class.perform_now(note_id: note.id)

    expect(note.reload).to be_status_discarded
  end

  it "skips notes already processed and missing ones" do
    note.update!(status: :processed)
    allow(Wikitech::ExtractEntries).to receive(:call)

    described_class.perform_now(note_id: note.id)
    described_class.perform_now(note_id: SecureRandom.uuid)

    expect(Wikitech::ExtractEntries).not_to have_received(:call)
  end

  it "leaves the note pending when the AI switch is off" do
    Settings::Global.instance.update!(ai_wikitech_enabled: false)
    allow(Wikitech::ExtractEntries).to receive(:call)

    described_class.perform_now(note_id: note.id)

    expect(Wikitech::ExtractEntries).not_to have_received(:call)
    expect(note.reload).to be_status_pending
  end

  it "retries a temporary AI failure" do
    allow(Wikitech::ExtractEntries).to receive(:call)
      .and_return(Result.err(AppError.new("down", code: "R503-LLM-001", status: :service_unavailable)))

    expect { described_class.perform_now(note_id: note.id) }.to have_enqueued_job(described_class)
  end

  it "records the failure on the note when the retries are over" do
    allow(Wikitech::ExtractEntries).to receive(:call)
      .and_return(Result.err(AppError.new("down", code: "R503-LLM-001", status: :service_unavailable)))
    job = described_class.new(note_id: note.id)
    # retry_on counts attempts per exception filter, not by `executions`.
    job.exception_executions = { [ TransientFailure ].to_s => ApplicationJob::MAX_ATTEMPTS - 1 }

    job.perform_now

    expect(note.reload).to have_attributes(status: "pending", last_error: "R503-LLM-001")
  end
end
