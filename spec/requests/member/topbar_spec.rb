# frozen_string_literal: true

require "rails_helper"

# Top bar of the member area (CYRA-898): organization, presence, search, bell and user menu.
RSpec.describe "Member top bar", type: :request do
  let(:doc) { Nokogiri::HTML(response.body) }
  let(:organization) { create(:organization, name: "Demo Organization") }
  let(:owner) { create(:account, name: "Olivia Holt", email: "olivia@example.com") }

  before { create(:membership, account: owner, organization: organization, role: :owner) }

  # The ticket list, not the home: the bar is the same everywhere and the home's decision queue
  # has its own lazy-loading trap with two memberships.
  def visit_home
    post login_path, params: { email: owner.email, password: "Secret123!" }
    get member_tickets_path
  end

  describe "organization" do
    it "shows the whole name up to 220px and the full name on hover" do
      visit_home

      switcher = doc.at_css("[data-test='member-org-switcher']")
      expect(switcher["class"]).to include("max-w-[220px]")
      expect(switcher["title"]).to eq("Demo Organization")
    end

    it "colors the swatch with the organization's own color" do
      visit_home

      swatch = doc.at_css("[data-test='member-org-swatch']")
      expect(swatch["class"]).to include(ApplicationController.helpers.organization_swatch_class(organization))
    end

    it "with a single organization shows the name without a menu" do
      visit_home

      switcher = doc.at_css("header [data-test='member-org-switcher']")
      expect(switcher.name).to eq("span")
      expect(switcher.at_css("svg[data-icon='chevron-down']")).to be_nil
    end

    it "with two organizations keeps the switch menu" do
      create(:membership, account: owner, organization: create(:organization, name: "Second"), role: :member)
      # Two memberships trip a lazy read in the ticket list's permission gate, outside the bar.
      allow_lazy_loading { visit_home }

      expect(doc.at_css("header details summary[data-test='member-org-switcher']")).to be_present
    end
  end

  describe "search" do
    it "reads as a search field with its shortcut on a wide topbar" do
      visit_home

      trigger = doc.at_css("[data-test='global-search-trigger-desktop']")
      expect(trigger["class"]).to include("@min-[980px]:w-[200px]")
      expect(trigger.at_css("[data-test='global-search-trigger-label']").text).to eq(I18n.t("member.search.trigger"))
      expect(trigger.at_css("kbd").text).to eq(I18n.t("member.search.shortcut"))
    end
  end

  describe "bell" do
    it "opens a preview panel loaded on demand" do
      visit_home

      menu = doc.at_css("details[data-test='notification-bell-menu']")
      expect(menu.at_css("summary[data-test='notification-bell']")).to be_present
      frame = menu.at_css("turbo-frame#notifications_preview")
      expect(frame["src"]).to eq(preview_member_alerting_notifications_path)
      expect(frame["loading"]).to eq("lazy")
    end
  end

  describe "user menu" do
    it "shows only the initials in the bar and name and email inside the menu" do
      visit_home

      trigger = doc.at_css("summary[data-test='member-user-menu']")
      expect(trigger.text).not_to include("Olivia Holt")
      expect(trigger["aria-label"]).to include("Olivia Holt")
      identity = doc.at_css("[data-test='user-menu-identity']")
      expect(identity.text).to include("Olivia Holt", "olivia@example.com")
    end
  end
end
