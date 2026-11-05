# frozen_string_literal: true

require "rails_helper"

# CYRA-1147 — the browser tab counts what is waiting. The counters cap their label at "99+", so each
# one also carries its exact number in `data-pending-count`, which the tab-badge controller sums.
RSpec.describe "Member tab badge counters", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  def doc = Nokogiri::HTML(response.body)

  it "attaches the tab-badge controller to the page wrapper" do
    get root_path

    expect(doc.at_css("[data-controller~='tab-badge']")).to be_present
  end

  describe "notifications counter" do
    it "carries the exact unread count of this organization" do
      create_list(:alerting_notification, 2, :unread, organization: org, account: owner)
      create(:alerting_notification, :unread, organization: create(:organization), account: owner)

      get root_path

      expect(doc.at_css("#alerting_notification_badge")["data-pending-count"]).to eq("2")
    end

    it "carries zero when nothing is unread" do
      get root_path

      expect(doc.at_css("#alerting_notification_badge")["data-pending-count"]).to eq("0")
    end
  end

  describe "approvals counter" do
    it "carries the exact number even when the label shows 99+" do
      allow(Home::Approvals::Queue).to receive(:awaiting_count).and_return(150)

      get member_home_approvals_count_path

      expect(doc.at_css("turbo-frame#member-nav-approvals-count [data-pending-count]")["data-pending-count"])
        .to eq("150")
      expect(doc.at_css("[data-test='member-nav-approvals-badge']").text).to eq("99+")
    end

    it "carries zero when nothing is waiting" do
      allow(Home::Approvals::Queue).to receive(:awaiting_count).and_return(0)

      get member_home_approvals_count_path

      expect(doc.at_css("turbo-frame#member-nav-approvals-count [data-pending-count]")["data-pending-count"])
        .to eq("0")
    end

    it "carries the last known count inside the sidebar frame before the new one arrives" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      allow(Home::Approvals::Queue).to receive(:awaiting_count).and_return(4)
      get member_home_approvals_count_path

      get root_path

      frame = doc.at_css("#member-sidebar turbo-frame#member-nav-approvals-count")
      expect(frame.at_css("[data-pending-count]")["data-pending-count"]).to eq("4")
    end
  end
end
