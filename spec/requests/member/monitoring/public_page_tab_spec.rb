# frozen_string_literal: true

require "rails_helper"

# CYRA-990 — the public status page of a monitor or a group lives in a "Public page" tab of its page.
RSpec.describe "Public page tab of monitors and groups (CYRA-990)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:environment) { create(:environment, organization: org).tap { |e| project.environments << e } }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  def doc = Nokogiri::HTML(response.body)
  # Publish/Unpublish is a button_to: the address sits on its form.
  def toggle_action(test_id) = doc.at_css("[data-test='#{test_id}']").ancestors("form").first["action"]

  describe "monitor" do
    let(:monitor) { create(:uptime_monitor, project:, environment:, public_status_enabled: true) }

    it "shows the two tabs, overview first" do
      get member_monitoring_monitor_path(monitor)

      expect(doc.at_css("[data-test='monitor-tab-overview']")["href"]).to eq(member_monitoring_monitor_path(monitor))
      expect(doc.at_css("[data-test='monitor-tab-public']")["href"]).to eq(member_monitoring_monitor_path(monitor, tab: "public"))
      expect(doc.at_css("[data-test='monitor-checks']")).to be_present
    end

    it "keeps the public link and the banner out of the overview" do
      get member_monitoring_monitor_path(monitor)

      expect(doc.at_css("[data-test='monitor-public-link']")).to be_nil
      expect(doc.at_css("[data-test='monitor-announcement']")).to be_nil
    end

    it "gathers state, toggle, link, preview and banner in the public tab" do
      get member_monitoring_monitor_path(monitor, tab: "public")

      expect(doc.at_css("[data-test='monitor-checks']")).to be_nil
      expect(toggle_action("monitor-public-toggle")).to eq(unpublish_member_monitoring_monitor_path(monitor))
      expect(doc.at_css("[data-test='monitor-public-link']")).to be_present
      expect(doc.at_css("[data-test='monitor-public-preview'] iframe")["src"])
        .to eq(public_status_url(org.slug, project.key, environment.code))
      expect(doc.at_css("[data-test='monitor-announcement']")).to be_present
    end

    it "offers Publish with its confirmation when the monitor is private, and no preview" do
      monitor.update!(public_status_enabled: false)
      get member_monitoring_monitor_path(monitor, tab: "public")

      expect(toggle_action("monitor-public-toggle")).to eq(publish_member_monitoring_monitor_path(monitor))
      expect(doc.at_css("[data-test='monitor-public-toggle']")["data-turbo-confirm"]).to eq(I18n.t("member.uptime.publish_confirm"))
      expect(doc.at_css("[data-test='monitor-public-preview']")).to be_nil
    end

    it "says when the monitor is already public through its group" do
      group = create(:uptime_group, :published, organization: org)
      monitor.update!(group:, public_status_enabled: false)
      get member_monitoring_monitor_path(monitor, tab: "public")

      note = doc.at_css("[data-test='monitor-public-via-group']")
      expect(note.text).to include(group.name)
      expect(note.at_css("a")["href"]).to eq(member_monitoring_uptime_group_path(group, tab: "public"))
    end

    it "returns to the public tab after publishing" do
      patch unpublish_member_monitoring_monitor_path(monitor)

      expect(response).to redirect_to(member_monitoring_monitor_path(monitor, tab: "public"))
    end
  end

  describe "group" do
    let(:group) { create(:uptime_group, :published, organization: org) }

    it "gathers state, toggle, link and preview in the public tab" do
      get member_monitoring_uptime_group_path(group, tab: "public")

      expect(doc.at_css("[data-test='uptime-group-monitors']")).to be_nil
      expect(toggle_action("uptime-group-public-toggle")).to eq(unpublish_member_monitoring_uptime_group_path(group))
      expect(doc.at_css("[data-test='uptime-group-public-link']")).to be_present
      expect(doc.at_css("[data-test='uptime-group-public-preview']")).to be_present
    end

    it "keeps the overview on the monitors of the group" do
      get member_monitoring_uptime_group_path(group)

      expect(doc.at_css("[data-test='uptime-group-monitors']")).to be_present
      expect(doc.at_css("[data-test='uptime-group-public-link']")).to be_nil
    end

    it "returns to the public tab after publishing" do
      patch unpublish_member_monitoring_uptime_group_path(group), params: { confirm: "1" }

      expect(response).to redirect_to(member_monitoring_uptime_group_path(group, tab: "public"))
    end
  end
end
