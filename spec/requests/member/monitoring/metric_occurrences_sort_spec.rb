# frozen_string_literal: true

require "rails_helper"

# CYRA-924 — the samples of one performance group sort on every column (C9).
RSpec.describe "Member — metric group occurrences sort", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization:) }
  let(:group) { create(:metric_group, project:) }

  before do
    create(:membership, account: owner, organization:, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
    create(:metric_sample, group:, duration_ms: 900.0, environment: "zeta-env", occurred_at: 2.minutes.ago,
                           payload: { "sql" => "SELECT 1", "query_count" => 3, "cached" => false })
    create(:metric_sample, group:, duration_ms: 10.0, environment: "alpha-env", occurred_at: 1.minute.ago,
                           payload: { "sql" => "SELECT 1", "query_count" => 40, "cached" => true })
  end

  def table = Nokogiri::HTML(response.body).at_css("[data-test='metric-group-samples']").to_html

  it "sorts by duration both ways" do
    get member_monitoring_metric_group_path(group, sort: "duration")
    expect(table.index("alpha-env")).to be < table.index("zeta-env")

    get member_monitoring_metric_group_path(group, sort: "-duration")
    expect(table.index("zeta-env")).to be < table.index("alpha-env")
  end

  it "sorts by query count read from the sample" do
    get member_monitoring_metric_group_path(group, sort: "-queries")
    expect(table.index("alpha-env")).to be < table.index("zeta-env")
  end

  it "renders sortable headers for every column" do
    get member_monitoring_metric_group_path(group)
    %w[when duration queries environment cached].each { |key| expect(response.body).to include("sort=#{key}").or include("sort=-#{key}") }
  end
end
