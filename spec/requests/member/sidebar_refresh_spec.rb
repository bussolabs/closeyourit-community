# frozen_string_literal: true

require "rails_helper"

# CYRA-903 — the sidebar after its refresh: counters on the pinned entries, group names that open the
# area overview, the Alerts group and the compact desktop mode.
RSpec.describe "Member sidebar refresh", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    org.update_column(:cto_id, owner.id)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  def doc = Nokogiri::HTML(response.body)
  def sidebar = doc.at_css("#member-sidebar")

  describe "approvals counter" do
    it "loads lazily, so the queue never slows down the page" do
      get root_path

      frame = sidebar.at_css("[data-test='member-nav-approvals'] turbo-frame#member-nav-approvals-count")
      expect(frame["src"]).to eq(member_home_approvals_count_path)
      expect(frame["loading"]).to eq("lazy")
    end

    it "counts the decisions waiting for the viewer" do
      # Bulk fixture in the setup: per-record queries of the factory, not a production N+1.
      allow_n_plus_one do
        2.times do
          create(:ticket, organization: org, project: project, reviewer: owner,
                          status: create(:ticket_status, :in_review, organization: org))
        end
      end

      get member_home_approvals_count_path

      badge = doc.at_css("turbo-frame#member-nav-approvals-count [data-test='member-nav-approvals-badge']")
      expect(badge.text).to eq("2")
    end

    it "shows the last known count inside the lazy frame, so the badge does not blink on the next page" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      # Bulk fixture in the setup: per-record queries of the factory, not a production N+1.
      allow_n_plus_one do
        create(:ticket, organization: org, project: project, reviewer: owner,
                        status: create(:ticket_status, :in_review, organization: org))
      end
      get member_home_approvals_count_path

      get root_path

      frame = sidebar.at_css("turbo-frame#member-nav-approvals-count")
      expect(frame["loading"]).to eq("lazy")
      expect(frame.at_css("[data-test='member-nav-approvals-badge']").text).to eq("1")
    end

    it "shows no badge when nothing is waiting" do
      get member_home_approvals_count_path

      expect(response).to have_http_status(:ok)
      expect(doc.at_css("[data-test='member-nav-approvals-badge']")).to be_nil
    end
  end

  it "shows unread conversations next to Conversations" do
    create(:alerting_notification, account: owner, organization: org, via: :in_app, event_type: :chat_message)

    get root_path

    expect(sidebar.at_css("[data-test='member-nav-conversations'] [data-test='member-nav-conversations-badge']").text)
      .to eq("1")
  end

  it "shows the items still to do next to Todos" do
    list = create(:todo_list, organization: org, account: owner)
    create(:todo_item, list: list, done: false)
    create(:todo_item, list: list, done: true, completed_at: Time.current)

    get root_path

    expect(sidebar.at_css("[data-test='member-nav-home-todos'] [data-test='member-nav-home-todos-badge']").text)
      .to eq("1")
  end

  it "links each group name to its overview and gives the chevron its own button" do
    get member_monitoring_error_groups_path

    link = sidebar.at_css("[data-test='member-nav-group-observability'] a[data-test='member-nav-observability-overview']")
    expect(link["href"]).to eq(member_observability_path)
    expect(link["aria-current"]).to eq("true")

    toggle = sidebar.at_css("[data-test='member-nav-toggle-observability']")
    expect(toggle["aria-expanded"]).to eq("true")
    expect(sidebar.at_css("##{toggle['aria-controls']}")["hidden"]).to be_nil
    expect(sidebar.at_css("#member-nav-items-vault")["hidden"]).not_to be_nil
  end

  it "opens the Alerts overview with its rules and notifications" do
    get member_alerts_path

    expect(response).to have_http_status(:ok)
    expect(sidebar.at_css("[data-test='member-nav-alerts-overview']")["aria-current"]).to eq("page")
    hrefs = doc.css("main a, [data-test='member-alerts-overview'] a").map { |a| a["href"] }
    expect(hrefs).to include(member_alerting_rules_path, member_alerting_notifications_path)
  end

  describe "compact mode" do
    it "renders the sidebar wide by default" do
      get root_path

      expect(sidebar["data-compact"]).to be_nil
      expect(sidebar.at_css("[data-test='member-nav-compact-toggle']").text.strip).to eq(I18n.t("member.nav.compact_collapse"))
    end

    it "renders it compact when the cookie asks for it" do
      cookies[:sidebar_compact] = "1"

      get root_path

      expect(sidebar.key?("data-compact")).to be(true)
      expect(sidebar.at_css("[data-test='member-nav-compact-toggle']").text.strip).to eq(I18n.t("member.nav.compact_expand"))
    end
  end
end
