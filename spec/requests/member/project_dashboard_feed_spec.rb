# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::ProjectDashboardFeed", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:settings_path) { member_project_settings_path(project, section: "dashboard") }

  before { create(:membership, account: owner, organization: org, role: :owner) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def create_feed(**attributes)
    create(:dashboards_feed, project: project, **attributes)
  end

  it "redirects a signed-out visitor to the login" do
    post member_project_dashboard_feed_path(project), params: { url: "https://service.example" }

    expect(response).to redirect_to(login_path)
  end

  it "answers 404 for a project of another organization (anti-BOLA)" do
    sign_in(owner)
    foreign = create(:project, organization: create(:organization))

    post member_project_dashboard_feed_path(foreign), params: { url: "https://service.example" }

    expect(response).to have_http_status(:not_found)
    expect(foreign.reload.dashboard_feed).to be_nil
  end

  it "refuses a member who sees the project without projects.edit and creates nothing" do
    member = create(:account)
    create(:membership, account: member, organization: org, role: :member)
    create(:project_membership, account: member, project: project)
    sign_in(member)

    post member_project_dashboard_feed_path(project), params: { url: "https://service.example" }

    expect(response).to redirect_to(root_path)
    expect(project.reload.dashboard_feed).to be_nil
  end

  it "connects the service and shows the key once, rendered directly" do
    sign_in(owner)

    post member_project_dashboard_feed_path(project), params: { url: "https://service.example" }

    expect(response).to have_http_status(:created)
    key = Nokogiri::HTML(response.body).at_css("[data-test='dashboard-key']")&.text
    expect(key).to match(/\Aod_[A-Za-z0-9]{40}\z/)
    expect(project.reload.dashboard_feed.url).to eq("https://service.example")
    expect(flash.to_hash.values.join).not_to include(key)
    expect(response.headers["Set-Cookie"].to_s).not_to include(key)
  end

  it "refuses a plain http address with the field error and no feed" do
    sign_in(owner)

    post member_project_dashboard_feed_path(project), params: { url: "http://service.example" }

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include(I18n.t("activerecord.errors.models.dashboards/feed.attributes.url.public_https"))
    expect(project.reload.dashboard_feed).to be_nil
  end

  it "pauses and resumes the feed" do
    feed = create_feed
    sign_in(owner)

    patch member_project_dashboard_feed_path(project), params: { enabled: "0" }
    expect(response).to redirect_to(settings_path)
    expect(feed.reload).not_to be_enabled

    patch member_project_dashboard_feed_path(project), params: { enabled: "1" }
    expect(feed.reload).to be_enabled
  end

  it "queues a read now" do
    feed = create_feed
    sign_in(owner)

    expect { post refresh_member_project_dashboard_feed_path(project) }
      .to have_enqueued_job(Dashboards::FetchFeedJob).with(feed.id)
    expect(response).to redirect_to(settings_path)
    expect(flash[:notice]).to be_present
  end

  it "disconnects the service" do
    create_feed
    sign_in(owner)

    delete member_project_dashboard_feed_path(project)

    expect(response).to redirect_to(settings_path)
    expect(flash[:notice]).to be_present
    expect(project.reload.dashboard_feed).to be_nil
  end

  describe "the Dashboard section of the settings page" do
    it "shows the address, the successful read and the controls for a connected service" do
      create_feed(payload: { "service" => { "name" => "shop" }, "metrics" => [] }, checked_at: 5.minutes.ago,
                  fetched_at: 5.minutes.ago)
      sign_in(owner)

      get settings_path

      document = Nokogiri::HTML(response.body)
      expect(document.at_css("[data-test='dashboard-url']")["value"]).to eq("https://service.example")
      expect(document.at_css("[data-test='dashboard-state']").text).to include(I18n.t("member.dashboards.settings.state_ok"))
      %w[dashboard-refresh dashboard-toggle dashboard-disconnect].each do |test_id|
        expect(document.at_css("[data-test='#{test_id}']")).to be_present
      end
      expect(document.at_css("[data-test='dashboard-connect']").text).to include(I18n.t("member.dashboards.settings.reconnect"))
    end

    it "shows the address field and the connect button without a feed" do
      sign_in(owner)

      get settings_path

      document = Nokogiri::HTML(response.body)
      expect(document.at_css("[data-test='dashboard-url']")).to be_present
      expect(document.at_css("[data-test='dashboard-connect']").text).to include(I18n.t("member.dashboards.settings.connect"))
      expect(document.at_css("[data-test='dashboard-refresh']")).to be_nil
    end
  end
end
