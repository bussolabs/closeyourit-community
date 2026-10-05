# frozen_string_literal: true

require "rails_helper"

RSpec.describe Logs::IngestJob do
  it "persiste i log via Record (singolo o array)" do
    project = create(:project)
    described_class.perform_now(project_id: project.id, payload: [
      { "event_id" => "a", "message" => "one", "level" => "info" },
      { "event_id" => "b", "message" => "two", "level" => "error" }
    ])
    expect(project.logs_entries.count).to eq(2)
  end

  it "usa la coda :ingest" do
    expect(described_class.new.queue_name).to eq("ingest")
  end

  it "scarta senza errore se il progetto non esiste" do
    expect do
      described_class.perform_now(project_id: SecureRandom.uuid, payload: { "message" => "x" })
    end.not_to raise_error
  end
end
