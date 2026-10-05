# frozen_string_literal: true

require "rails_helper"

# CYRA-924 — the Logs bar follows C61/C62: the period is a chip of the Filters menu, as on Errors,
# and the grouping is a "Group by" choice of the View menu, saved with the view.
RSpec.describe "Member — Logs toolbar", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization:) }

  before do
    create(:membership, account: owner, organization:, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
    create(:log_entry, project:, message: "Domain not verified", occurred_at: 1.hour.ago,
                       fingerprint: Logs::Fingerprint.call(message: "Domain not verified", level: :info))
  end

  def html = Nokogiri::HTML(response.body)

  describe "period as a filter chip" do
    it "drops the always-visible range buttons" do
      get member_monitoring_log_entries_path

      expect(html.at_css("[data-test='time-range']")).to be_nil
      expect(html.at_css("[data-test='filter-menu-range']")).to be_present
    end

    it "keeps the chip hidden on the default range" do
      get member_monitoring_log_entries_path(range: "24h")

      expect(html.at_css("[data-test='filter-chip-range']")["hidden"]).not_to be_nil
    end

    it "shows the chip with the chosen range" do
      get member_monitoring_log_entries_path(range: "7d")

      chip = html.at_css("[data-test='filter-chip-range']")
      expect(chip["hidden"]).to be_nil
      expect(chip.at_css("input[type='hidden'][name='range']")["value"]).to eq("7d")
    end

    it "offers the two dates inside the chip for a custom range" do
      get member_monitoring_log_entries_path(range: "custom", from: "2026-07-09T14:00")

      chip = html.at_css("[data-test='filter-chip-range']")
      expect(chip.at_css("[data-test='logs-range-from']")["value"]).to eq("2026-07-09T14:00")
      expect(chip.at_css("[data-test='logs-range-to']")).to be_present
    end
  end

  describe "group by in the View menu" do
    it "replaces the toggle with two choices, the active one checked" do
      get member_monitoring_log_entries_path(grouped: "1")

      expect(html.at_css("[data-test='logs-group-toggle']")).to be_nil
      menu = html.at_css("[data-test='logs-toolbar-view-menu']")
      expect(menu.at_css("[data-test='logs-group-by-message']")["aria-current"]).to eq("true")
      expect(menu.at_css("[data-test='logs-group-by-none']")["href"]).not_to include("grouped=1")
    end

    it "starts on one list" do
      get member_monitoring_log_entries_path

      expect(html.at_css("[data-test='logs-group-by-none']")["aria-current"]).to eq("true")
      expect(html.at_css("[data-test='logs-group-by-message']")["href"]).to include("grouped=1")
    end
  end
end
