# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::BackfillEmbeddingsJob, type: :job do
  include ActiveJob::TestHelper

  it "accoda EmbedPageJob solo per le pagine stale" do
    stale = create(:knowledge_page)
    fresh = create(:knowledge_page)
    fresh.update_columns(embedding: basis_vector(0),
                         embedding_checksum: Knowledge::EmbeddingText.checksum(page: fresh))

    described_class.perform_now

    enqueued = enqueued_jobs.select { |job| job["job_class"] == "Knowledge::EmbedPageJob" }
    ids = enqueued.map { |job| job["arguments"].first["page_id"] }
    expect(ids).to include(stale.id)
    expect(ids).not_to include(fresh.id)
  end
end
