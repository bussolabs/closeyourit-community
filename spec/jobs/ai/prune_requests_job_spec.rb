# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ai::PruneRequestsJob, type: :job do
  around { |example| travel_to(Time.zone.local(2026, 11, 20, 12)) { example.run } }

  [ 0, 1, 1001 ].each do |count|
    it "deletes #{count} expired requests in batches and keeps the retention boundary" do
      boundary = create(:ai_request, created_at: 1.day.ago)
      fresh = create(:ai_request)
      attributes = boundary.attributes.except("id").merge("created_at" => 1.day.ago - 1.second)
      Ai::Request.insert_all!(Array.new(count) { attributes }) if count.positive?
      deleted = []
      allow(Ai::Request.connection).to receive(:delete).and_wrap_original do |original, *args, **kwargs|
        original.call(*args, **kwargs).tap { |rows| deleted << rows }
      end

      described_class.perform_now

      expect(Ai::Request.pluck(:id)).to contain_exactly(boundary.id, fresh.id)
      expect(deleted.sum).to eq(count)
      expect(deleted).to all(be <= 1000)
      expect(deleted.count(&:positive?)).to eq((count / 1000.0).ceil)

      described_class.perform_now

      expect(Ai::Request.pluck(:id)).to contain_exactly(boundary.id, fresh.id)
      expect(deleted.sum).to eq(count)
    end
  end
end
