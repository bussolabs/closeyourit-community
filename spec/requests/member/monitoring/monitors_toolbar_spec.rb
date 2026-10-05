# frozen_string_literal: true

require "rails_helper"

# CYRA-924 — the uptime period is a chip of the Filters menu (C61), not always-visible pills.
RSpec.describe "Member — uptime monitors toolbar", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization:) }

  before do
    create(:membership, account: owner, organization:, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
    create(:uptime_monitor, project:)
  end

  def html = Nokogiri::HTML(response.body)

  it "drops the range pills for a Filters chip" do
    get member_monitoring_monitors_path

    expect(html.at_css("[data-test='range-selector']")).to be_nil
    expect(html.at_css("[data-test='filter-menu-range']")).to be_present
    expect(html.at_css("[data-test='filter-chip-range']")["hidden"]).not_to be_nil
  end

  it "shows the chip with the chosen range, the default as the blank first option" do
    get member_monitoring_monitors_path(range: "7d")

    chip = html.at_css("[data-test='filter-chip-range']")
    expect(chip["hidden"]).to be_nil
    expect(chip.at_css("select[name='range'] option[selected]")["value"]).to eq("7d")
    expect(chip.css("select[name='range'] option").map { |o| o["value"] }).to eq([ "", "30m", "7d", "30d", "1y" ])
  end

  it "sends the range once, from the chip only" do
    get member_monitoring_monitors_path(range: "7d")

    expect(html.css("[data-test='monitors-toolbar'] form[method='get'] [name='range']").size).to eq(1)
  end

  # CYRA-924 — uptime and response sort too (C9), in both views; they are computed, so in memory.
  describe "sort on computed columns" do
    let!(:steady) { create(:uptime_monitor, project: create(:project, organization:, name: "Steady site")) }
    let!(:flaky) { create(:uptime_monitor, project: create(:project, organization:, name: "Flaky site")) }

    before do
      create(:uptime_check, monitor: steady, up: true, response_time_ms: 900, checked_at: 5.minutes.ago)
      create(:uptime_check, monitor: flaky, up: false, response_time_ms: 50, checked_at: 5.minutes.ago)
    end

    %w[table grouped].each do |view|
      it "#{view}: sorts by uptime and by response" do
        rows = -> { html.css("tr[id^='uptime_monitor_']").map(&:text).join }
        get member_monitoring_monitors_path(view:, sort: "-uptime")
        expect(rows.call.index("Steady site")).to be < rows.call.index("Flaky site")

        get member_monitoring_monitors_path(view:, sort: "-response")
        expect(rows.call.index("Steady site")).to be < rows.call.index("Flaky site")
        %w[monitor status uptime response last_check].each { |key| expect(response.body).to include("sort=#{key}").or include("sort=-#{key}") }
      end
    end
  end
end
