# frozen_string_literal: true

require "rails_helper"

# CYRA-924 — a list is one panel: the search bar is its header row, never a strip above it.
RSpec.describe "Member — monitoring lists keep the bar inside the panel", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization:) }

  before do
    create(:membership, account: owner, organization:, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  def html = Nokogiri::HTML(response.body)

  # The bordered panel the toolbar lives in, if any.
  def panel_around(test_id)
    html.at_css("[data-test='#{test_id}']").ancestors.find { |node| node["class"].to_s.split.include?("rounded-lg") && node["class"].to_s.split.include?("border") }
  end

  it "errors: the toolbar sits inside the results panel" do
    create(:error_group, project:, last_seen_at: 1.hour.ago)

    get member_monitoring_error_groups_path

    expect(panel_around("errors-toolbar")&.at_css("turbo-frame#errors-results")).to be_present
  end

  it "logs: the toolbar sits inside the results panel" do
    create(:log_entry, project:, occurred_at: 1.hour.ago)

    get member_monitoring_log_entries_path

    expect(panel_around("logs-toolbar")&.at_css("turbo-frame#logs-results")).to be_present
  end
end
