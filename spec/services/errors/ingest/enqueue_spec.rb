# frozen_string_literal: true

require "rails_helper"

# CYRA-211 — Il payload d'ingest non deve entrare negli argomenti del job in coda: ci va solo un
# riferimento (l'id della riga di staging), il corpo vive in Errors::IngestPayload.
RSpec.describe Errors::Ingest::Enqueue, type: :service do
  include ActiveJob::TestHelper
  include_context "an error with colliding field names"

  def event = payload

  it "stages repaired collisions safely and processes the stored payload" do
    staged = described_class.call(project: project, payload: colliding_error)
    expect_safe_collision_payload(staged.reload.payload)
    perform_enqueued_jobs(only: Errors::IngestJob)
    expect_safe_collision_payload(project.error_events.sole.payload)
    expect(Errors::IngestPayload.exists?(staged.id)).to be(false)
  end

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

  # CYRA-1218: un byte nullo nel nome di un campo faceva fallire il salvataggio della riga di staging.
  it "accetta un errore con il byte nullo nel nome di un campo" do
    sporco = payload.merge("extra" => { "chi#{0.chr}ave" => "v", "chiave" => "pulito" })

    staged = nil
    expect { staged = described_class.call(project: project, payload: sporco) }
      .to change(Errors::IngestPayload, :count).by(1)
    expect(staged.reload.payload["extra"]).to eq("chiave" => "pulito", "chiave_2" => "v")
  end
end
