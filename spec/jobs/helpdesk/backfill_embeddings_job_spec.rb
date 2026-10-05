# frozen_string_literal: true

require "rails_helper"

RSpec.describe Helpdesk::BackfillEmbeddingsJob, type: :job do
  include ActiveJob::TestHelper

  it "enqueues EmbedRequestJob only for stale requests (CYRA-914 P8)" do
    stale = create(:helpdesk_request)
    fresh = create(:helpdesk_request)
    fresh.update_columns(embedding: basis_vector(0),
                         embedding_checksum: Helpdesk::EmbeddingText.checksum(request: fresh))

    described_class.perform_now

    enqueued = enqueued_jobs.select { |job| job["job_class"] == "Helpdesk::EmbedRequestJob" }
    ids = enqueued.map { |job| job["arguments"].first["request_id"] }
    expect(ids).to include(stale.id)
    expect(ids).not_to include(fresh.id)
  end
end
