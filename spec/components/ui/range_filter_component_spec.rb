# frozen_string_literal: true

require "rails_helper"

# CYRA-985 — presets and custom dates in one control.
RSpec.describe Ui::RangeFilterComponent, type: :component do
  OPTIONS = [ [ "24 hours", "" ], [ "7 days", "7d" ], [ "Custom", "custom" ] ].freeze

  def render_filter(**overrides)
    defaults = { name: "range", label: "Range", options: OPTIONS, custom: "custom",
                 test_id: "filter-range", bounds_test_prefix: "errors-range" }
    render_inline(described_class.new(**defaults.merge(overrides)))
  end

  def at(day, hour, minute) = Time.zone.local(2026, 10, day, hour, minute)

  it "shows the default preset when nothing is selected" do
    render_filter
    expect(page.find("summary").text).to include("Range:").and include("24 hours")
  end

  it "shows the selected preset and marks it in the list" do
    render_filter(selected: "7d")
    expect(page.find("summary").text).to include("7 days")
    expect(page).to have_css("button[data-value='7d'][aria-pressed='true']", visible: :all)
    expect(page).to have_css("input[type='hidden'][name='range'][value='7d']", visible: :all)
  end

  it "writes the date once when both bounds fall on the same day" do
    render_filter(selected: "custom", from: at(2, 20, 30), to: at(2, 21, 0))
    expect(page.find("summary").text).to include("2 Oct, 20:30 → 21:00")
  end

  it "writes both dates when the bounds fall on different days" do
    render_filter(selected: "custom", from: at(2, 20, 30), to: at(3, 9, 0))
    expect(page.find("summary").text).to include("2 Oct 20:30 → 3 Oct 09:00")
  end

  it "names the open side when only one bound is set" do
    render_filter(selected: "custom", from: at(2, 20, 30))
    expect(page.find("summary").text).to include("from 2 Oct 20:30")
  end

  it "falls back to the custom label when no bound is set" do
    render_filter(selected: "custom")
    expect(page.find("summary").text).to include("Custom")
  end

  it "keeps the value in a hidden field the filter bar can read, never a native select" do
    render_filter
    expect(page).to have_css("input[type='hidden'][name='range'][data-test='filter-range'][data-filter-bar-value]", visible: :all)
    expect(page).to have_no_css("select", visible: :all)
  end

  it "offers every preset as a button, the custom one as two dates and Apply" do
    render_filter(selected: "custom", from: at(2, 20, 30), to: at(2, 21, 0))
    expect(page.all("button[data-value]", visible: :all).map { |b| b["data-value"] }).to eq([ "", "7d" ])
    expect(page.find("[data-test='errors-range-from']", visible: :all)["value"]).to eq("2026-10-02T20:30")
    expect(page.find("[data-test='errors-range-to']", visible: :all)["value"]).to eq("2026-10-02T21:00")
    expect(page).to have_css("button[data-test='errors-range-apply']", visible: :all)
  end
end
