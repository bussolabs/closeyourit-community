# frozen_string_literal: true

require "rails_helper"

RSpec.describe Analytics::Overview do
  let(:org) { create(:organization) }
  let(:site_a) { create(:project, organization: org, name: "Alpha") }
  let(:site_b) { create(:project, organization: org, name: "Beta") }
  let(:now) { Time.current }

  def row_for(project) = described_class.new(projects: [ site_a, site_b ], range: "7d", now: now).rows.find { |r| r.project == project }

  it "counts pageviews and visitors of the period per site" do
    create(:pageview, project: site_a, visitor_hash: "v1", occurred_at: 1.day.ago)
    create(:pageview, project: site_a, visitor_hash: "v1", occurred_at: 2.days.ago)
    create(:pageview, project: site_a, visitor_hash: "v2", occurred_at: 3.days.ago)
    create(:pageview, project: site_b, visitor_hash: "v3", occurred_at: 1.day.ago)

    expect(row_for(site_a)).to have_attributes(pageviews: 3, visitors: 2)
    expect(row_for(site_b)).to have_attributes(pageviews: 1, visitors: 1)
  end

  it "counts the previous period of the same length apart" do
    create(:pageview, project: site_a, occurred_at: 1.day.ago)
    create(:pageview, project: site_a, occurred_at: 10.days.ago)
    create(:pageview, project: site_a, occurred_at: 11.days.ago)

    expect(row_for(site_a)).to have_attributes(pageviews: 1, previous_pageviews: 2, previous_visitors: 2)
  end

  it "leaves out health checks, other environments and custom events" do
    create(:pageview, project: site_a, path: "/up", occurred_at: 1.hour.ago)
    create(:pageview, project: site_a, environment: "staging", occurred_at: 1.hour.ago)
    create(:pageview, project: site_a, name: "Signup", occurred_at: 1.hour.ago)

    expect(row_for(site_a)).to have_attributes(pageviews: 0, visitors: 0)
  end

  it "says who is on the site right now and when the last visit arrived" do
    create(:pageview, project: site_a, occurred_at: 1.minute.ago)
    create(:pageview, project: site_b, occurred_at: 20.days.ago)

    expect(row_for(site_a).online).to eq(1)
    expect(row_for(site_b).online).to eq(0)
    expect(row_for(site_b).last_at).to be_within(1.second).of(20.days.ago)
  end

  it "draws one trend point per bucket of the period" do
    create(:pageview, project: site_a, occurred_at: 1.hour.ago)

    trend = row_for(site_a).trend
    expect(trend.size).to eq(Analytics::Pageview.bucket_config("7d")[:count])
    expect(trend.sum).to eq(1)
  end

  it "returns a row with zeros for a site that never received a visit" do
    expect(row_for(site_b)).to have_attributes(pageviews: 0, visitors: 0, online: 0, last_at: nil, connected: false)
  end

  # Linux clocks carry nanoseconds, the database keeps microseconds: each bucket came back a hair
  # early and `floor` moved it one step back, the oldest one into the "now" slot.
  context "when the clock has nanoseconds" do
    let(:now) { Time.at(Time.current.to_i, 123_456_789, :nsec).in_time_zone }

    it "puts each visit in its own bucket" do
      cfg = Analytics::Pageview.bucket_config("7d")
      create(:pageview, project: site_a, occurred_at: now - 1.hour)
      create(:pageview, project: site_a, occurred_at: now - (cfg[:count] * cfg[:seconds]) + 1.minute)

      trend = row_for(site_a).trend
      expect(trend.first).to eq(1)
      expect(trend.last).to eq(1)
      expect(trend.sum).to eq(2)
    end
  end

  # The last visit follows the row it sits in; "connected" follows the dashboard: any event at all.
  it "dates the last visit with the rules of the row, and calls connected any site that sent something" do
    create(:pageview, project: site_a, environment: "staging", occurred_at: 1.day.ago)
    create(:pageview, project: site_b, name: "Signup", occurred_at: 1.day.ago)

    expect(row_for(site_a)).to have_attributes(last_at: nil, connected: true)
    expect(row_for(site_b)).to have_attributes(last_at: nil, connected: true)
  end

  it "counts who is online now exactly as the dashboard does" do
    create(:pageview, project: site_a, path: "/up", visitor_hash: "probe", occurred_at: 1.minute.ago)
    create(:pageview, project: site_a, visitor_hash: "ahead", occurred_at: now + 30.seconds)
    dashboard = Analytics::Query.new(project_id: site_a.id, range: "7d", environment: "production", now: now)

    expect(row_for(site_a).online).to eq(dashboard.realtime_count)
    expect(row_for(site_a).online).to eq(2)
  end
end
