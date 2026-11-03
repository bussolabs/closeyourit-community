# frozen_string_literal: true

require "rails_helper"

# CYRA-1145 — the quick search also offers actions on the open ticket, settings by name and the
# thing a pasted link points to. Every entry stays inside what the viewer can already see or do.
RSpec.describe "Member::Searches commands", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: organization, name: "Apollo") }
  let(:ticket) { create(:ticket, :plain_bug, organization: organization, project: project, title: "Login broken") }
  let(:html) { Nokogiri::HTML(response.body) }

  before do
    create(:membership, account: owner, organization: organization, role: :owner)
    sign_in(owner)
  end

  def sign_in(account)
    delete logout_path
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def search(query, context: nil)
    get member_search_path, params: { q: query, context: context }.compact,
                            headers: { "Turbo-Frame" => "member-global-search-results" }
  end

  def visible_member
    create(:account).tap do |member|
      create(:membership, account: member, organization: organization, role: :member)
      create(:project_membership, account: member, project: project)
    end
  end

  describe "actions on the open ticket" do
    it "offers assign to me first, as a PATCH to the assignee endpoint" do
      search("assign", context: member_ticket_path(ticket))

      first_group = html.at_css("[data-test='global-search-groups'] section")
      expect(first_group["data-test"]).to eq("global-search-group-actions")
      entry = html.at_css("[data-test='global-search-result-action-assign']")
      expect(entry["href"]).to eq(assignee_member_ticket_path(ticket, assignee_id: owner.id))
      expect(entry["data-turbo-method"]).to eq("patch")
    end

    it "offers a move to every other status, matched by the status name" do
      ticket # takes the first open status, so the new one below is another
      other = create(:ticket_status, organization: organization, label: "Waiting review")

      search("waiting", context: member_ticket_path(ticket))

      entry = html.at_css("[data-test='global-search-result-action-status-#{other.id}']")
      expect(entry["href"]).to eq(status_member_ticket_path(ticket, status_id: other.id, inline: 1))
      expect(html.at_css("[data-test='global-search-result-action-status-#{ticket.status_id}']")).to be_nil
    end

    it "offers handing the ticket to the agents through the eligibility endpoint" do
      search("automation", context: member_ticket_path(ticket))

      entry = html.at_css("[data-test='global-search-result-action-automation']")
      expect(entry["href"]).to eq(member_ticket_eligibility_path(ticket, eligibility: "allowed"))
      expect(entry["data-turbo-confirm"]).to be_present
    end

    it "shows the actions greyed out with the reason to whoever cannot change the ticket" do
      sign_in(visible_member)

      search("automation", context: member_ticket_path(ticket))

      entry = html.at_css("[data-test='global-search-result-action-automation']")
      expect(entry.name).not_to eq("a")
      expect(entry["aria-disabled"]).to eq("true")
      expect(entry.text).to include(I18n.t("member.search.actions.blocked.edit"))
    end

    it "offers no actions away from a ticket page" do
      search("assign", context: member_projects_path)

      expect(html.at_css("[data-test='global-search-group-actions']")).to be_nil
    end

    it "offers no actions on a ticket the viewer does not see" do
      foreign = create(:ticket, organization: create(:organization))

      search("assign", context: member_ticket_path(foreign))

      expect(html.at_css("[data-test='global-search-group-actions']")).to be_nil
    end

    it "keeps the open page in the filter links" do
      search("assign", context: member_ticket_path(ticket))

      chip = html.at_css("[data-test='global-search-filter-actions']")
      expect(chip["href"]).to eq(member_search_path(q: "assign", type: "actions", context: member_ticket_path(ticket)))
    end
  end

  describe "settings by name" do
    it "links a project settings section that opens highlighted" do
      search("retention", context: member_project_path(project))

      entry = html.at_css("[data-test='global-search-result-setting-#{project.id}-retention']")
      expect(entry["href"]).to eq(member_project_settings_path(project, highlight: "retention", anchor: "retention"))
    end

    it "finds the personal notification preferences" do
      search(I18n.t("member.nav.bottom_notifications"))

      entry = html.at_css("[data-test='global-search-result-setting-notifications']")
      expect(entry["href"]).to eq(member_notification_preferences_path)
    end

    it "hides sections the viewer cannot open" do
      sign_in(visible_member)

      search("retention", context: member_project_path(project))

      expect(html.at_css("[data-test='global-search-result-setting-#{project.id}-retention']")).to be_nil
    end

    it "points every catalogued section at a panel of the settings page" do
      get member_project_settings_path(project)

      anchors = Nokogiri::HTML(response.body).css("[data-section-panels-target='panel']").map { |panel| panel["data-anchor"] }
      expect(Search::SettingsCatalog::PROJECT_SECTIONS.keys - anchors).to be_empty
    end
  end

  describe "pasted links" do
    it "finds the ticket linked to a GitHub pull request and puts it first" do
      create(:github_pull_request, ticket: ticket, html_url: "https://github.com/acme/app/pull/42")

      search("https://github.com/acme/app/pull/42/files")

      first_group = html.at_css("[data-test='global-search-groups'] section")
      expect(first_group["data-test"]).to eq("global-search-group-tickets")
      expect(html.at_css("[data-test='global-search-result-ticket-#{ticket.id}']")).to be_present
    end

    it "finds the ticket an internal link opens" do
      search("https://www.closeyour.it#{member_ticket_path(ticket)}")

      expect(html.at_css("[data-test='global-search-result-ticket-#{ticket.id}']")).to be_present
    end

    it "does not reveal a ticket the viewer does not see" do
      hidden_project = create(:project, organization: organization)
      hidden = create(:ticket, :plain_bug, organization: organization, project: hidden_project, title: "Secret plan")
      create(:github_pull_request, ticket: hidden, html_url: "https://github.com/acme/app/pull/7")
      sign_in(visible_member)

      search("https://github.com/acme/app/pull/7")
      expect(response.body).not_to include("Secret plan")

      search("http://localhost#{member_ticket_path(hidden)}")
      expect(response.body).not_to include("Secret plan")
    end
  end
end
