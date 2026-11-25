# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::LinkPreviews::PruneJob, type: :job do
  include ActiveJob::TestHelper

  it "removes previews expired for longer than the retention, image included" do
    old = create(:link_preview, :with_image, expires_at: (described_class::RETENTION + 1.day).ago)
    recent = create(:link_preview, expires_at: 2.days.ago)
    blob_id = old.image.blob.id

    perform_enqueued_jobs { described_class.perform_now }

    expect(Ticketing::LinkPreview.exists?(old.id)).to be(false)
    expect(Ticketing::LinkPreview.exists?(recent.id)).to be(true)
    expect(ActiveStorage::Blob.exists?(blob_id)).to be(false)
  end
end
