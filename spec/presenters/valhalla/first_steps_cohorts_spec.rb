# frozen_string_literal: true

require "rails_helper"

# CYRA-1159 — first steps by signup week, preexisting organizations in a row of their own.
RSpec.describe Valhalla::FirstStepsCohorts do
  let(:now) { Time.utc(2026, 11, 5, 12) } # a Thursday
  let(:this_week) { Date.new(2026, 11, 2) }

  def rows = described_class.new(now: now).rows

  it "counts the organizations of a week and how many reached each step" do
    organizations = Array.new(3) { create(:organization, created_at: Time.utc(2026, 11, 3, 9)) }
    Organizations::FirstStep.record!(:telegram, organization_ids: organizations.first.id)
    Organizations::FirstStep.record!(:first_error, organization_ids: organizations.first(2).map(&:id))

    week = rows.find { |row| row.week == this_week }

    expect(week.signed_up).to eq(3)
    expect(week.reached("telegram")).to eq(1)
    expect(week.reached("first_error")).to eq(2)
    expect(week.reached("ticket_closed")).to eq(0)
  end

  it "shows the last twelve weeks newest first, then the preexisting row" do
    result = rows

    expect(result.size).to eq(described_class::WEEKS + 1)
    expect(result.first.week).to eq(this_week)
    expect(result[-2].week).to eq(this_week - 11.weeks)
    expect(result.last).to be_preexisting
  end

  it "keeps the preexisting organizations out of the weeks" do
    old = create(:organization, created_at: Time.utc(2026, 11, 3), first_steps_preexisting: true)
    Organizations::FirstStep.record!(:invitation, organization_ids: old.id)
    create(:organization, created_at: Time.utc(2025, 1, 1)) # older than twelve weeks, not preexisting

    result = rows

    expect(result.find { |row| row.week == this_week }.signed_up).to eq(0)
    expect(result.last.signed_up).to eq(1)
    expect(result.last.reached("invitation")).to eq(1)
    expect(result.sum(&:signed_up)).to eq(1)
  end
end
