# frozen_string_literal: true

require "rails_helper"

# The overview of one monitor keeps everything inside panels (T1) and shows an open incident as a red
# border on the Uptime panel, not as a banner over the page (A15).
RSpec.describe "Monitor overview layout", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:environment) { create(:environment, organization: org).tap { |e| project.environments << e } }
  let(:monitor) { create(:uptime_monitor, project:, environment:) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  def panel = Nokogiri::HTML(response.body).at_css("[data-test='response-chart']")

  it "puts the range selector in the Uptime panel header" do
    get member_monitoring_monitor_path(monitor)

    expect(panel.at_css("[data-test='range-selector'] [data-test='range-7d']")["href"])
      .to eq(member_monitoring_monitor_path(monitor, range: "7d"))
  end

  it "puts the SLA figures inside the Uptime panel" do
    get member_monitoring_monitor_path(monitor)

    expect(panel.at_css("[data-test='sla-summary'] [data-test='sla-30d']")).to be_present
  end

  it "marks an open incident with a red border on the Uptime panel" do
    create(:uptime_incident, monitor:, started_at: 2.hours.ago, resolved_at: nil)
    get member_monitoring_monitor_path(monitor)

    expect(panel["class"]).to include("border-red-300")
    expect(panel.at_css("[data-test='open-incident']").text).to include(I18n.t("member.uptime.ongoing_incident"))
  end

  it "keeps the Uptime panel border neutral without an open incident" do
    get member_monitoring_monitor_path(monitor)

    expect(panel["class"]).not_to include("border-red")
    expect(panel.at_css("[data-test='open-incident']")).to be_nil
  end

  it "puts the incidents title inside the incidents panel" do
    create(:uptime_incident, monitor:, started_at: 2.hours.ago, resolved_at: nil)
    get member_monitoring_monitor_path(monitor)

    title = Nokogiri::HTML(response.body).at_css("[data-test='incidents'] h2")
    expect(title.ancestors("div.rounded-lg")).not_to be_empty
  end
end
