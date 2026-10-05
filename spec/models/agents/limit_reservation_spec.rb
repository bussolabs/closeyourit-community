# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::LimitReservation, type: :model do
  def reservation_attributes(organization:)
    {
      organization:,
      runtime: "claude",
      idempotency_key: SecureRandom.uuid,
      requested_ttl_seconds: 60,
      outcome: "granted",
      expires_at: 1.minute.from_now
    }
  end

  it "rifiuta project e host di tenant differenti" do
    organization = create(:organization)
    foreign = create(:organization)
    record = described_class.new(
      **reservation_attributes(organization:),
      project: create(:project, organization: foreign),
      host: create(:agent_host, organization: foreign)
    )

    expect(record).not_to be_valid
    expect(record.errors.attribute_names).to include(:project, :host)
  end

  it "impone una forma esclusiva per decisioni granted e denied" do
    organization = create(:organization)
    granted = described_class.new(
      **reservation_attributes(organization:).merge(expires_at: nil),
      denial_reason: "max_parallel"
    )
    denied = described_class.new(
      **reservation_attributes(organization:).merge(outcome: "denied"),
      denial_reason: nil
    )

    expect(granted).not_to be_valid
    expect(granted.errors.attribute_names).to include(:expires_at, :denial_reason)
    expect(denied).not_to be_valid
    expect(denied.errors.attribute_names).to include(:expires_at, :denial_reason)
  end
end
