# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboards::ReportView do
  def metric(key, type:, value:, previous: nil, better: nil, group: "Users", **extra)
    { "key" => key, "label" => key.titleize, "group" => group, "type" => type, "value" => value,
      "previous" => previous, "period" => (previous.nil? ? nil : "30d"), "better" => better }.compact.merge(extra)
  end

  def view_for(metrics, last_error: nil)
    payload = { "open_dashboard" => "1.0", "generated_at" => "2026-10-25T10:00:00Z",
                "service" => { "name" => "Scontino", "version" => "v2.14.1", "environment" => "production" },
                "metrics" => metrics }
    described_class.new(build(:dashboards_feed, payload:, last_error:))
  end

  around { |example| I18n.with_locale(:en) { example.run } }

  it "is :never without a saved report, :failed with a last error, :ok otherwise" do
    expect(described_class.new(build(:dashboards_feed, payload: nil)).state).to eq(:never)
    expect(view_for([], last_error: "timeout").state).to eq(:failed)
    expect(view_for([]).state).to eq(:ok)
  end

  it "exposes the service identity" do
    expect(view_for([]).service).to eq(name: "Scontino", version: "v2.14.1", environment: "production")
  end

  it "formats a count and its rise as good when up is better" do
    m = view_for([ metric("users.total", type: "count", value: 12_480, previous: 11_752, better: "up") ]).metrics.first

    expect(m).to have_attributes(value_text: "12,480", delta_text: "+6.2%", direction: :up, tone: :good)
  end

  it "marks a rise as bad when down is better" do
    m = view_for([ metric("subs.lost", type: "count", value: 42, previous: 37, better: "down") ]).metrics.first

    expect(m).to have_attributes(direction: :up, tone: :bad)
  end

  it "keeps the arrow neutral when the service does not say which way is better" do
    m = view_for([ metric("x.y", type: "count", value: 5, previous: 4) ]).metrics.first

    expect(m.tone).to eq(:neutral)
  end

  it "formats money from cents with its currency" do
    m = view_for([ metric("rev.month", type: "money", value: 1_842_050, currency: "EUR") ]).metrics.first

    expect(m.value_text).to eq("18,420.50 EUR")
  end

  it "formats a percent and its change in points" do
    m = view_for([ metric("conv.rate", type: "percent", value: 14.2, previous: 13.4, better: "up") ]).metrics.first

    expect(m).to have_attributes(value_text: "14.2%", delta_text: "+0.8 pt", tone: :good)
  end

  it "formats a duration in hours, minutes and seconds" do
    m = view_for([ metric("redeem.avg", type: "duration", value: 134) ]).metrics.first

    expect(m.value_text).to eq("2 min 14 s")
  end

  it "shows an unavailable metric as a dash with no delta" do
    m = view_for([ metric("lists.shared", type: "count", value: nil, error: "unavailable") ]).metrics.first

    expect(m).to have_attributes(value_text: "—", unavailable?: true, delta_text: nil)
  end

  it "has no delta when the previous value is zero or missing" do
    metrics = view_for([ metric("a.b", type: "count", value: 3, previous: 0), metric("a.c", type: "count", value: 3) ]).metrics

    expect(metrics.map(&:delta_text)).to eq([ nil, nil ])
  end

  it "is flat when nothing changed" do
    m = view_for([ metric("a.b", type: "count", value: 3, previous: 3, better: "up") ]).metrics.first

    expect(m).to have_attributes(delta_text: "0%", direction: :flat, tone: :neutral)
  end

  it "groups metrics in the order the service declared them" do
    view = view_for([ metric("a.a", type: "count", value: 1, group: "Users"),
                      metric("b.a", type: "count", value: 1, group: "Billing"),
                      metric("a.b", type: "count", value: 1, group: "Users") ])

    expect(view.groups.map { |name, list| [ name, list.map(&:key) ] })
      .to eq([ [ "Users", %w[a.a a.b] ], [ "Billing", %w[b.a] ] ])
  end

  it "puts the first four metrics in the headline" do
    view = view_for((1..6).map { |i| metric("m.k#{i}", type: "count", value: i) })

    expect(view.headline.map(&:key)).to eq(%w[m.k1 m.k2 m.k3 m.k4])
  end

  it "formats numbers the Italian way in Italian" do
    m = I18n.with_locale(:it) { view_for([ metric("users.total", type: "count", value: 12_480) ]).metrics.first }

    expect(m.value_text).to eq("12.480")
  end
end
