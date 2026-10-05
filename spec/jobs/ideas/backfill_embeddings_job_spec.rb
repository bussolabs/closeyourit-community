# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ideas::BackfillEmbeddingsJob, type: :job do
  include ActiveJob::TestHelper

  it "accoda EmbedIdeaJob solo per le idee stale" do
    stale = create(:idea)
    fresh = create(:idea)
    fresh.update_columns(embedding: basis_vector(0),
                         embedding_checksum: Ideas::EmbeddingText.checksum(idea: fresh))

    described_class.perform_now

    enqueued = enqueued_jobs.select { |job| job["job_class"] == "Ideas::EmbedIdeaJob" }
    ids = enqueued.map { |job| job["arguments"].first["idea_id"] }
    expect(ids).to include(stale.id)
    expect(ids).not_to include(fresh.id)
  end
end
