# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ai::PruneRequestsJob, type: :job do
  it "elimina solo le richieste oltre la retention" do
    stale = create(:ai_request, created_at: Ai::Constants::REQUESTS_RETENTION.ago - 1.minute)
    fresh = create(:ai_request)

    described_class.perform_now

    expect(Ai::Request).not_to exist(stale.id)
    expect(Ai::Request).to exist(fresh.id)
  end
end
