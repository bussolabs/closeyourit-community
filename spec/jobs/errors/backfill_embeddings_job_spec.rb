# frozen_string_literal: true

require "rails_helper"

RSpec.describe Errors::BackfillEmbeddingsJob do
  it "accoda i gruppi stale e salta quelli col checksum fresco" do
    fresh = create(:error_group)
    fresh.update_columns(embedding: basis_vector(0),
                         embedding_checksum: Errors::EmbeddingText.checksum(group: fresh))
    stale = create(:error_group, title: "Vecchio")

    expect { described_class.perform_now }
      .to have_enqueued_job(Errors::EmbedGroupJob).with(group_id: stale.id).exactly(:once)
    expect(Errors::EmbedGroupJob).not_to have_been_enqueued.with(group_id: fresh.id)
  end
end
