# frozen_string_literal: true

require "rails_helper"

# CYRA-1159 — the list shows until the five steps are done or the list is closed, then never again.
RSpec.describe Organizations::FirstSteps::Checklist do
  let(:organization) { create(:organization) }

  it "lists the five steps undone for a new organization" do
    checklist = described_class.for(organization)

    expect(checklist.items.map(&:step)).to eq(Organizations::FirstStep::STEPS)
    expect(checklist.items).to all(have_attributes(done?: false))
    expect(checklist.done_count).to eq(0)
  end

  it "ticks the steps taken, with their day" do
    Organizations::FirstStep.record!(:first_error, organization_ids: organization.id)

    checklist = described_class.for(organization)

    expect(checklist.items.select(&:done?).map(&:step)).to eq([ "first_error" ])
    expect(checklist.done_count).to eq(1)
  end

  it "is gone once the five steps are done" do
    Organizations::FirstStep::STEPS.each { |step| Organizations::FirstStep.record!(step, organization_ids: organization.id) }

    expect(described_class.for(organization)).to be_nil
  end

  it "is gone once the list was closed" do
    organization.update_columns(first_steps_dismissed_at: Time.current)

    expect(described_class.for(organization)).to be_nil
  end

  it "may be closed by owner and admin only" do
    expect(described_class.dismissable_by?(build(:membership, role: :owner))).to be(true)
    expect(described_class.dismissable_by?(build(:membership, role: :admin))).to be(true)
    expect(described_class.dismissable_by?(build(:membership, role: :member))).to be(false)
    expect(described_class.dismissable_by?(nil)).to be(false)
  end
end
