# frozen_string_literal: true

require "rails_helper"

# CYRA-924 — a saved Logs view keeps the grouping and the period, like the uptime one.
RSpec.describe SavedView, "log entries keys" do
  it "keeps grouped and range among the saved filters" do
    expect(SavedView::FILTER_KEYS["log_entries"]).to include("grouped", "range")
  end

  it "keeps the grouping when saved without the filters" do
    expect(SavedView.view_keys("log_entries")).to contain_exactly("grouped", "sort")
  end
end
