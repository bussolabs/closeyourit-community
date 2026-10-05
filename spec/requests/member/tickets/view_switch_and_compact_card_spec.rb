# frozen_string_literal: true

require "rails_helper"

# CYRA-901 — board and list share one Board | List switch next to the search, carrying the common
# filters; board cards show priority and warnings as named icons instead of text badges.
RSpec.describe "Member::Tickets view switch and compact cards (CYRA-901)", type: :request do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:status) { create(:ticket_status, organization: org) }
  let(:high) { create(:ticket_priority, organization: org, code: "high", label: "High", color: "orange") }
  let(:owner) do
    create(:account).tap { |account| create(:membership, account: account, organization: org, role: :owner) }
  end

  before { post login_path, params: { email: owner.email, password: "Secret123!" } }

  def html = Capybara.string(response.body)

  describe "view switch" do
    # CYRA-924 — board or list is a choice of the View menu (C62), not buttons in the bar.
    it "sits in the board View menu with Board checked and replaces the header button" do
      get member_tickets_path

      switch = html.find("[data-test='board-toolbar-view-menu'] [data-test='tickets-view-switch']", visible: :all)
      expect(switch).to have_css("[data-test='tickets-view-board'][aria-current='true']", visible: :all)
      expect(switch).to have_css("[data-test='tickets-view-list'][href^='#{list_member_tickets_path}']", visible: :all)
      expect(html).not_to have_css("[data-test='board-list-view']")
    end

    it "sits in the list View menu with List checked, and the bar holds no count" do
      get list_member_tickets_path

      switch = html.find("[data-test='tickets-toolbar-view-menu'] [data-test='tickets-view-switch']", visible: :all)
      expect(switch).to have_css("[data-test='tickets-view-list'][aria-current='true']", visible: :all)
      expect(switch).to have_css("[data-test='tickets-view-board'][href^='#{member_tickets_path}']", visible: :all)
      expect(html.find("[data-test='tickets-toolbar']")).to have_no_text(I18n.t("member.tickets.count", count: 0))
      expect(html).not_to have_css("[data-test='tickets-board-view']")
    end

    it "carries the common filters to the other view and drops the list-only ones" do
      get list_member_tickets_path(project_id: [ project.id ], q: "checkout", status_id: [ status.id ], sort: "title")

      href = html.find("[data-test='tickets-view-board']", visible: :all)[:href]
      query = Rack::Utils.parse_nested_query(URI.parse(href).query)
      expect(query).to include("project_id" => [ project.id ], "q" => "checkout")
      expect(query.keys).not_to include("status_id", "sort")
    end

    it "declares the carried filters even when there are none, so the destination does not restore older ones" do
      get member_tickets_path(RememberableFilters::MARKER_PARAM => 1)

      href = html.find("[data-test='tickets-view-list']", visible: :all)[:href]
      expect(Rack::Utils.parse_nested_query(URI.parse(href).query)).to eq("ft" => "1")
    end

    it "keeps the page subtitle" do
      get member_tickets_path

      expect(html).to have_css("[data-test='board-header-subtitle']", text: I18n.t("member.tickets.help_title", locale: :en))
    end
  end

  describe "compact board card" do
    it "shows the priority as a named icon instead of a text badge" do
      ticket = create(:ticket, organization: org, project: project, status: status, priority: high)

      get member_tickets_path

      card = html.find("[data-test='board-card-#{ticket.id}']")
      icon = card.find("[data-test='board-card-priority-#{ticket.id}']")
      expect(icon[:title]).to eq("High")
      expect(icon).to have_css("svg[data-icon='arrow-up']", visible: :all)
      expect(icon).to have_css(".sr-only", text: "High", visible: :all)
    end

    it "shows the open questions as an icon with its count and an accessible name" do
      ticket = create(:ticket, organization: org, project: project, status: status)
      create(:ticket_question, ticket: ticket, organization: org, author: owner)

      get member_tickets_path

      flag = html.find("[data-test='board-card-open-questions-#{ticket.id}']")
      expect(flag).to have_text("1")
      expect(flag[:title]).to be_present
      expect(flag).not_to have_text(I18n.t("member.tickets.open_questions.badge", count: 1, locale: :en))
    end
  end
end
