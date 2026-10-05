# frozen_string_literal: true

require "rails_helper"

# D16 — a number you can act on links to the list already filtered: the counts on top of an area
# page open the page they count, and the "down" ones open it filtered on what is down.
RSpec.describe "Member — area page counts are links", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }

  before do
    create(:project, organization:)
    create(:membership, account: owner, organization:, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  def count_link(group, key)
    Capybara.string(response.body).find("a[data-test='#{group}-count-#{key}']")[:href]
  end

  it "observability: unreachable checks open Uptime filtered on down" do
    get member_observability_path

    expect(count_link("observability", "monitors_down")).to eq(member_monitoring_monitors_path(status: [ "down" ]))
    expect(count_link("observability", "errors")).to eq(member_monitoring_error_groups_path(ft: 1, status: [ "unresolved" ]))
  end

  it "infrastructure: unreachable machines open Servers filtered on down" do
    get member_infrastructure_path

    expect(count_link("infrastructure", "servers_down")).to eq(member_monitoring_servers_path(status: [ "down" ]))
    expect(count_link("infrastructure", "servers")).to eq(member_monitoring_servers_path)
  end

  it "administration: people, service accounts and projects open their pages" do
    get member_settings_path

    expect(count_link("settings", "members")).to eq(member_members_path)
    expect(count_link("settings", "service_accounts")).to eq(member_service_accounts_path)
  end
end
