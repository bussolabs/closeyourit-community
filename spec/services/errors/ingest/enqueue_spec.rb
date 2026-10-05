# frozen_string_literal: true

require "rails_helper"

# CYRA-211 — Il payload d'ingest non deve entrare negli argomenti del job in coda: ci va solo un
# riferimento (l'id della riga di staging), il corpo vive in Errors::IngestPayload.
RSpec.describe Errors::Ingest::Enqueue, type: :service do
  include ActiveJob::TestHelper

  let(:project) { create(:project) }
  let(:payload) do
    { "event_id" => "e1", "level" => "error",
      "exception" => { "values" => [ { "type" => "RuntimeError", "value" => "boom" } ] } }
  end

  it "stadia il payload e accoda il job col solo id (mai il payload)" do
    expect { described_class.call(project: project, payload: payload) }
      .to have_enqueued_job(Errors::IngestJob).with(payload_id: kind_of(String))
      .and change(Errors::IngestPayload, :count).by(1)
  end

  it "la riga di staging conserva il payload integro e il progetto" do
    staged = described_class.call(project: project, payload: payload)

    expect(staged.reload.payload).to eq(payload)
    expect(staged.project).to eq(project)
  end

  it "in coda viaggia un riferimento, non il corpo dell'evento (Scenario 1)" do
    described_class.call(project: project, payload: payload)

    expect(enqueued_jobs.size).to eq(1)
    expect(enqueued_jobs.first.to_json).not_to include("boom")
  end
end
