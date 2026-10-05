# frozen_string_literal: true

require "rails_helper"

# CYRA-211 — Gli orfani dei job d'ingest scartati dopo i retry non devono accumularsi: la potatura
# raccoglie le staging più vecchie della finestra, lasciando intatte quelle appena arrivate.
RSpec.describe Errors::PruneIngestPayloadsJob, type: :job do
  let(:project) { create(:project) }

  it "cancella le staging oltre la finestra e tiene quelle recenti" do
    old = Errors::IngestPayload.create!(project: project, payload: { "event_id" => "old" },
                                        created_at: described_class::RETENTION.ago - 1.hour)
    recent = Errors::IngestPayload.create!(project: project, payload: { "event_id" => "new" })

    described_class.perform_now

    expect(Errors::IngestPayload.exists?(old.id)).to be(false)
    expect(Errors::IngestPayload.exists?(recent.id)).to be(true)
  end
end
