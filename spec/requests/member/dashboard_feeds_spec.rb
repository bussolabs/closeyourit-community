# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::DashboardFeeds", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }

  before { create(:membership, account: owner, organization: org, role: :owner) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def report(value: 12_480)
    { "service" => { "name" => "shop", "version" => "v2.14.1", "environment" => "production" },
      "metrics" => [
        { "key" => "users", "label" => "Users", "group" => "People", "type" => "count", "value" => value,
          "previous" => 12_000, "period" => "30d" },
        { "key" => "mrr", "label" => "MRR", "group" => "Revenue", "type" => "money", "currency" => "EUR",
          "value" => 428_000, "previous" => 396_000, "period" => "30d" },
        { "key" => "churn", "label" => "Churn", "group" => "Revenue", "type" => "percent", "better" => "down",
          "value" => 3.1, "previous" => 3.6, "period" => "30d" },
        { "key" => "reply", "label" => "First reply", "group" => "Support", "type" => "duration", "value" => 5400 },
        { "key" => "fifth", "label" => "Fifth number", "group" => "Support", "type" => "count", "value" => 7 }
      ] }
  end

  def connected(name:, organization: org, **attributes)
    project = create(:project, organization: organization, name: name)
    create(:dashboards_feed, project: project, payload: report, checked_at: 4.minutes.ago,
                             fetched_at: 4.minutes.ago, **attributes)
  end

  def page = Nokogiri::HTML(response.body)

  it "redirects a signed-out visitor to the login" do
    get member_dashboard_feeds_path

    expect(response).to redirect_to(login_path)
  end

  it "shows a member only the services of the projects they see" do
    member = create(:account)
    create(:membership, account: member, organization: org, role: :member)
    seen = connected(name: "Seen shop")
    create(:project_membership, account: member, project: seen.project)
    hidden = connected(name: "Hidden shop")
    foreign = connected(name: "Foreign shop", organization: create(:organization))
    sign_in(member)

    get member_dashboard_feeds_path

    expect(response).to have_http_status(:ok)
    expect(page.at_css("[data-test='dashboard-card-#{seen.id}']")).to be_present
    expect(page.at_css("[data-test='dashboard-card-#{hidden.id}']")).to be_nil
    expect(page.at_css("[data-test='dashboard-card-#{foreign.id}']")).to be_nil
    expect(response.body).not_to include("Hidden shop", "Foreign shop")
  end

  it "shows the project, the version and the first four numbers on the card of a service read" do
    feed = connected(name: "Shop")
    sign_in(owner)

    get member_dashboard_feeds_path

    card = page.at_css("[data-test='dashboard-card-#{feed.id}']")
    expect(card.text).to include("Shop", "v2.14.1", "12,480", "4,280.00 EUR", "3.1%", "1 h 30 min")
    expect(card.text).not_to include("Fifth number")
    expect(card.at_css("[data-test='dashboard-card-state']").text).to include("Read 4 minutes ago")
    expect(card.at_css("[data-tone='good']")).to be_present
  end

  it "marks a failed read and still shows the last good numbers" do
    feed = connected(name: "Shop", last_error: "timeout")
    sign_in(owner)

    get member_dashboard_feeds_path

    card = page.at_css("[data-test='dashboard-card-#{feed.id}']")
    expect(card.at_css("[data-test='dashboard-card-state']").text).to include("Read failed")
    expect(card.text).to include("12,480")
  end

  it "filters by project name and says when nothing matches" do
    shop = connected(name: "Shop")
    blog = connected(name: "Blog")
    sign_in(owner)

    get member_dashboard_feeds_path, params: { q: "sho" }

    expect(page.at_css("[data-test='dashboard-card-#{shop.id}']")).to be_present
    expect(page.at_css("[data-test='dashboard-card-#{blog.id}']")).to be_nil

    get member_dashboard_feeds_path, params: { q: "nothing like this" }

    expect(page.at_css("[data-test='dashboards-no-match']")).to be_present
  end

  it "filters by the state of the last read" do
    ok = connected(name: "Shop")
    failed = connected(name: "Blog", last_error: "timeout")
    sign_in(owner)

    get member_dashboard_feeds_path, params: { state: "failed" }

    expect(page.at_css("[data-test='dashboard-card-#{failed.id}']")).to be_present
    expect(page.at_css("[data-test='dashboard-card-#{ok.id}']")).to be_nil
  end

  it "shows twelve cards, then Show more" do
    13.times { |i| connected(name: format("Shop %02d", i)) }
    sign_in(owner)

    get member_dashboard_feeds_path

    expect(page.css("[data-test^='dashboard-card-']").map { _1["data-test"] }.grep(/\Adashboard-card-[0-9a-f-]+\z/).size).to eq(12)
    expect(page.at_css("[data-test='dashboards-more']")).to be_present
  end

  describe "projects to connect" do
    let!(:unconnected) { create(:project, organization: org, name: "Waiting") }

    before { connected(name: "Shop") }

    it "lists them for whoever can edit the project, pointing to its settings" do
      sign_in(owner)

      get member_dashboard_feeds_path

      item = page.at_css("[data-test='dashboards-setup-#{unconnected.id}']")
      expect(item).to be_present
      expect(item["href"]).to eq(member_project_settings_path(unconnected, section: "dashboard"))
    end

    it "hides them from a member without projects.edit" do
      member = create(:account)
      create(:membership, account: member, organization: org, role: :member)
      create(:project_membership, account: member, project: unconnected)
      sign_in(member)

      get member_dashboard_feeds_path

      expect(page.at_css("[data-test='dashboards-setup-#{unconnected.id}']")).to be_nil
    end
  end

  it "shows the empty state when no service is connected" do
    sign_in(owner)

    get member_dashboard_feeds_path

    expect(page.at_css("[data-test='dashboards-empty']")).to be_present
  end

  it "lights the Dashboard entry inside the Products group" do
    connected(name: "Shop")
    sign_in(owner)

    get member_dashboard_feeds_path

    entry = page.at_css("[data-test='member-nav-group-product'] [data-test='member-nav-dashboards']")
    expect(entry).to be_present
    expect(entry["aria-current"]).to eq("page")
  end

  it "draws several cards grouped and ungrouped without loading associations row by row" do
    group = create(:group, organization: org)
    3.times { |i| connected(name: "Shop #{i}").project.update!(group: (group if i.zero?)) }
    sign_in(owner)

    get member_dashboard_feeds_path

    expect(response).to have_http_status(:ok)
    expect(page.at_css("[data-test='dashboards-group-#{group.id}']")).to be_present
    expect(page.at_css("[data-test='dashboards-ungrouped']")).to be_present

    get member_dashboard_feeds_path, params: { grouped: "none" }

    expect(page.at_css("[data-test='dashboards-all']")).to be_present
  end
  describe "one service" do
    it "answers 404 for a service whose project the viewer does not see" do
      member = create(:account)
      create(:membership, account: member, organization: org, role: :member)
      hidden = connected(name: "Hidden shop")
      foreign = connected(name: "Foreign shop", organization: create(:organization))
      sign_in(member)

      get member_dashboard_feed_path(hidden)
      expect(response).to have_http_status(:not_found)

      get member_dashboard_feed_path(foreign)
      expect(response).to have_http_status(:not_found)
    end

    it "shows the numbers grouped in the service's order, with the change colored by its tone" do
      feed = connected(name: "Shop")
      feed.update!(payload: report.merge("metrics" => report["metrics"] + [
        { "key" => "shared", "label" => "Shared lists", "group" => "Support", "type" => "count", "value" => nil,
          "error" => "query failed" }
      ]))
      sign_in(owner)

      get member_dashboard_feed_path(feed)

      expect(response).to have_http_status(:ok)
      expect(page.css("[data-test='dashboard-group'] h2").map { _1.text.strip }).to eq(%w[People Revenue Support])
      expect(page.at_css("[data-test='dashboard-header']").text).to include("Shop", "v2.14.1", "production", "30 days before")
      users = page.at_css("[data-test='dashboard-metric-users']")
      expect(users.text).to include("Users", "12,480", "+4%", "compared with 30 days before")
      expect(users.at_css("[data-tone='neutral']")).to be_present
      expect(page.at_css("[data-test='dashboard-metric-churn'] [data-tone='good']").text).to include("▼", "−0.5 pt")
      expect(page.at_css("[data-test='dashboard-metric-mrr']").text).to include("4,280.00 EUR")
      expect(page.at_css("[data-test='dashboard-metric-fifth']").text).to include("no comparison")
      expect(page.at_css("[data-test='dashboard-metric-shared']").text).to include("not available")
      expect(page.at_css("[data-test='dashboard-read-failed']")).to be_nil
    end

    it "gives every group its own panel, with the numbers split by hairlines and no panel inside a panel (A12)" do
      feed = connected(name: "Shop")
      sign_in(owner)

      get member_dashboard_feed_path(feed)

      numbers = page.at_css("[data-test='dashboard-numbers']")
      expect(numbers.css("[data-test='dashboard-group']").size).to eq(3)
      expect(numbers.css("[data-test='dashboard-group'] [class*='rounded']")).to be_empty
      expect(numbers.css("[data-test^='dashboard-metric-']").map { _1[:class] }).to all(satisfy { |klass| !klass.include?("rounded-[10px]") })
    end

    it "says why the last read failed and still shows the last good numbers" do
      feed = connected(name: "Shop", last_error: "timeout")
      sign_in(owner)

      get member_dashboard_feed_path(feed)

      expect(page.at_css("[data-test='dashboard-read-failed']").text).to include("did not answer within 10 seconds")
      expect(page.at_css("[data-test='dashboard-metric-users']").text).to include("12,480")
    end

    it "says the service was never read and shows nothing else" do
      project = create(:project, organization: org, name: "Shop")
      feed = create(:dashboards_feed, project: project, payload: nil, checked_at: nil, fetched_at: nil)
      sign_in(owner)

      get member_dashboard_feed_path(feed)

      expect(page.at_css("[data-test='dashboard-never-read']")).to be_present
      expect(page.at_css("[data-test='dashboard-group']")).to be_nil
    end

    it "offers Read now and Settings only to whoever can edit the project" do
      feed = connected(name: "Shop")
      sign_in(owner)

      get member_dashboard_feed_path(feed)

      expect(page.at_css("[data-test='dashboard-refresh']")).to be_present
      expect(page.at_css("[data-test='dashboard-settings']")["href"])
        .to eq(member_project_settings_path(feed.project, section: "dashboard"))

      member = create(:account)
      create(:membership, account: member, organization: org, role: :member)
      create(:project_membership, account: member, project: feed.project)
      delete logout_path
      sign_in(member)

      get member_dashboard_feed_path(feed)

      expect(response).to have_http_status(:ok)
      expect(page.at_css("[data-test='dashboard-refresh']")).to be_nil
      expect(page.at_css("[data-test='dashboard-settings']")).to be_nil
    end
  end
end
