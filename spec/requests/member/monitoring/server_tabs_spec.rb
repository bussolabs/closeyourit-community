# frozen_string_literal: true

require "rails_helper"

# The server page had become one very long scroll: charts, disks, containers, services and the system
# log one after the other. It is now split into tabs, and it opens on a short overview that says how
# the machine is doing and what needs doing, each line leading to the tab with the detail.
RSpec.describe "Member::Monitoring::Servers — tabs and quick overview", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:host) do
    create(:server_host, organization: org, name: "worker-01", status: :up, last_seen_at: Time.current,
           cpu_pct: 70.5, mem_pct: 75.8, disk_pct: 41.2, load_1: 2.58,
           reboot_required: true, security_updates_available: 6, services_total: 40, services_failed: 1,
           systemd_services: [ { "name" => "backup.service", "state" => "failed", "sub" => "failed" } ])
  end

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  def doc = Nokogiri::HTML(response.body)

  it "always shows the tabs, with Overview active by default" do
    get member_monitoring_server_path(host)

    tabs = doc.css("[data-test^='server-tab-']").map { |tab| tab["data-test"] }
    expect(tabs).to include("server-tab-overview", "server-tab-metrics", "server-tab-hardware",
                            "server-tab-workloads", "server-tab-log", "server-tab-operations",
                            "server-tab-alerts")
    expect(doc.at_css("[data-test='server-tab-overview'][aria-current='page']")).to be_present
  end

  it "opens on a quick overview: current vitals and what needs doing, without the long blocks" do
    get member_monitoring_server_path(host)

    vitals = doc.at_css("[data-test='server-vitals']")
    expect(vitals).to be_present
    %w[cpu mem disk load].each { |metric| expect(vitals.at_css("[data-test='server-vital-#{metric}']")).to be_present }
    expect(vitals.at_css("[data-test='server-vital-cpu']").text).to include("70.5%")

    attention = doc.at_css("[data-test='server-attention']")
    expect(attention.text).to include(I18n.t("member.servers.overview.reboot"))
    expect(attention.at_css("a[href*='tab=operations']")).to be_present # reboot and updates are run there
    expect(attention.at_css("a[href*='tab=workloads']")).to be_present  # the failed service

    %w[server-section-cpu server-containers server-journal server-smart].each do |block|
      expect(doc.at_css("[data-test='#{block}']")).to be_nil, "#{block} belongs to another tab"
    end
  end

  it "shows the specifications as a panel of the overview, not as a second line under the tabs" do
    get member_monitoring_server_path(host)

    expect(doc.at_css("[data-test='server-tabs'] [data-test='server-labels']")).to be_nil
    expect(doc.at_css("[data-test='server-labels'] [data-test='server-hostname']")).to be_present
    expect(doc.at_css("[data-test='server-labels'] [data-test='server-reboot']")).to be_present # the machine's facts too
  end

  it "says the machine is fine when nothing needs doing" do
    host.update!(reboot_required: false, security_updates_available: 0, services_failed: 0, systemd_services: [])
    get member_monitoring_server_path(host)

    expect(doc.at_css("[data-test='server-attention']").text).to include(I18n.t("member.servers.overview.all_fine"))
  end

  {
    "metrics" => %w[server-charts server-section-cpu server-section-memory],
    "hardware" => %w[server-smart],
    "workloads" => %w[server-containers server-systemd],
    "log" => %w[server-journal],
    "operations" => %w[server-actions],
    "alerts" => %w[server-alert-rules]
  }.each do |tab, blocks|
    it "shows on the #{tab} tab only its own blocks" do
      get member_monitoring_server_path(host, tab: tab)

      expect(doc.at_css("[data-test='server-tab-#{tab}'][aria-current='page']")).to be_present
      blocks.each { |block| expect(doc.at_css("[data-test='#{block}']")).to be_present, "#{block} missing on #{tab}" }
      expect(doc.at_css("[data-test='server-vitals']")).to be_nil
    end
  end

  it "puts containers and processes side by side on the workloads tab" do
    get member_monitoring_server_path(host, tab: "workloads")

    grid = doc.at_css("[data-test='server-containers']").parent
    expect(grid["class"]).to include("xl:grid-cols-2")
  end

  it "puts the metric panels two per row, each with the same range in its title row" do
    get member_monitoring_server_path(host, tab: "metrics", range: "7d")

    expect(doc.at_css("[data-test='server-charts']")["class"]).to include("xl:grid-cols-2")
    expect(doc.at_css("[data-test='server-tabs'] [data-test='range-selector']")).to be_nil
    selectors = doc.css("[data-test='server-section-cpu'] [data-test='range-selector'], " \
                        "[data-test='server-section-memory'] [data-test='range-selector']")
    expect(selectors.size).to eq(2)
    selectors.each { |selector| expect(selector.at_css("[data-test='range-7d']")["class"]).to include("bg-white") }
  end

  it "keeps the tab when the range of the charts changes" do
    get member_monitoring_server_path(host, tab: "metrics")

    expect(doc.at_css("[data-test='range-7d']")["href"]).to include("tab=metrics", "range=7d")
  end

  it "falls back to the overview on an unknown tab" do
    get member_monitoring_server_path(host, tab: "nope")

    expect(doc.at_css("[data-test='server-vitals']")).to be_present
  end
end
