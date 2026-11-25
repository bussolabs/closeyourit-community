# frozen_string_literal: true

require "rails_helper"

# CYRA-1159 — a step is written once: a repeat never moves its first day.
RSpec.describe Organizations::FirstStep do
  let(:organization) { create(:organization) }

  it "records a step with its day" do
    described_class.record!(:invitation, organization_ids: organization.id, at: Time.zone.local(2026, 11, 2, 10))

    expect(organization.first_steps.pluck(:step, :reached_at))
      .to eq([ [ "invitation", Time.zone.local(2026, 11, 2, 10) ] ])
  end

  it "ignores a repeat and keeps the first day" do
    described_class.record!(:first_error, organization_ids: organization.id, at: 3.days.ago.beginning_of_minute)
    3.times { described_class.record!(:first_error, organization_ids: organization.id) }

    expect(organization.first_steps.count).to eq(1)
    expect(organization.first_steps.first.reached_at).to eq(3.days.ago.beginning_of_minute)
  end

  it "records the same step for several organizations at once" do
    other = create(:organization)

    described_class.record!(:telegram, organization_ids: [ organization.id, other.id, nil ])

    expect(described_class.where(step: "telegram").pluck(:organization_id)).to contain_exactly(organization.id, other.id)
  end

  it "refuses a step outside the five" do
    expect { described_class.record!(:onboarding, organization_ids: organization.id) }.to raise_error(ArgumentError)
  end

  describe ".record" do
    it "records like record! when the write succeeds" do
      described_class.record(:invitation, organization_ids: organization.id)

      expect(organization.first_steps.pluck(:step)).to eq([ "invitation" ])
    end

    it "never breaks the caller's transaction when the write fails" do
      allow(described_class).to receive(:insert_all).and_raise(ActiveRecord::StatementInvalid, "boom")

      Organizations::Organization.transaction do
        expect(described_class.record(:invitation, organization_ids: organization.id)).to be_nil
        organization.update_columns(name: "Still writable")
      end

      expect(organization.reload.name).to eq("Still writable")
      expect(organization.first_steps).to be_empty
    end
  end

  it "falls with its organization" do
    described_class.record!(:alert_rule, organization_ids: organization.id)

    expect { organization.destroy! }.to change(described_class, :count).by(-1)
  end
end
