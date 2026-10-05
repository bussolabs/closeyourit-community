# frozen_string_literal: true

require "rails_helper"

# CYRA-924 — the containers and the processes of one server sort on every column (C9), each with
# its own param so the two tables do not move together.
RSpec.describe "Member — server page tables sort", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let!(:host) { create(:server_host, organization:, name: "apps", status: :up, last_seen_at: Time.current) }

  before do
    create(:membership, account: owner, organization:, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
    create(:server_sample, host:, recorded_at: 1.minute.ago,
                           payload: { "processes" => [ { "name" => "ruby-big", "pid" => 1, "cpu_pct" => 5.0, "mem_bytes" => 900 },
                                                       { "name" => "node-small", "pid" => 2, "cpu_pct" => 90.0, "mem_bytes" => 10 } ] })
    at = 1.minute.ago
    create(:server_container_sample, host:, name: "zeta-web", cpu_pct: 80.0, recorded_at: at)
    create(:server_container_sample, host:, name: "alpha-db", cpu_pct: 2.0, recorded_at: at)
  end

  def section(test_id) = Nokogiri::HTML(response.body).at_css("[data-test='#{test_id}']").to_html

  it "sorts containers by name and by cpu" do
    get member_monitoring_server_path(host, tab: "workloads", containers_sort: "name")
    expect(section("server-containers").index("alpha-db")).to be < section("server-containers").index("zeta-web")

    get member_monitoring_server_path(host, tab: "workloads", containers_sort: "-cpu")
    expect(section("server-containers").index("zeta-web")).to be < section("server-containers").index("alpha-db")
  end

  it "sorts processes by memory" do
    get member_monitoring_server_path(host, tab: "workloads", processes_sort: "-mem")
    expect(section("server-processes").index("ruby-big")).to be < section("server-processes").index("node-small")
  end

  it "offers every column of both tables" do
    get member_monitoring_server_path(host, tab: "workloads")
    %w[name health cpu mem net].each { |key| expect(response.body).to include("containers_sort=#{key}").or include("containers_sort=-#{key}") }
    %w[name pid cpu mem].each { |key| expect(response.body).to include("processes_sort=#{key}").or include("processes_sort=-#{key}") }
  end
end
