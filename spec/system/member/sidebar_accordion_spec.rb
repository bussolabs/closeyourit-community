# frozen_string_literal: true

require "rails_helper"

# CYRA-582 — one sidebar group open at a time, and the group of the open page always wins over the
# remembered one. CYRA-903 — groups are no longer <details>: the name links to the overview and the
# chevron is a button with aria-expanded.
RSpec.describe "Member sidebar — one group open at a time", type: :system do
  let(:org) { create(:organization) }

  def account_with(role)
    account = create(:account)
    create(:membership, account: account, organization: org, role: role)
    account
  end

  def open_groups
    page.all("#member-sidebar [data-test^='member-nav-toggle-'][aria-expanded='true']", visible: :all)
        .map { |toggle| toggle["data-test"].delete_prefix("member-nav-toggle-") }
  end

  describe "server markup" do
    before { driven_by(:rack_test) }

    def sign_in_as(account)
      visit login_path
      fill_test "login-email", with: account.email
      fill_test "login-password", with: "Secret123!"
      click_on_test "login-submit"
    end

    it "opens at most one group on any page" do
      sign_in_as(account_with(:owner))

      [ root_path, member_tickets_path, member_monitoring_error_groups_path,
        member_monitoring_seo_sites_path, member_personal_secrets_path ].each do |path|
        visit path

        expect(open_groups.size).to be <= 1, "#{path} renders #{open_groups.size} open groups: #{open_groups}"
      end
    end

    it "hides the leaves of every closed group" do
      sign_in_as(account_with(:owner))
      visit member_tickets_path

      expect(page).to have_css("#member-nav-items-product:not([hidden])", visible: :all)
      expect(page).to have_css("#member-nav-items-vault[hidden]", visible: :all)
    end
  end

  describe "in the browser", :js do
    def open(id)
      find("[data-test='member-nav-toggle-#{id}']").click
      expect(page).to have_css("[data-test='member-nav-toggle-#{id}'][aria-expanded='true']")
    end

    it "closes the first group when a second one opens" do
      sign_in_as(account_with(:owner))
      visit root_path

      open("product")
      expect(open_groups).to eq([ "product" ])

      open("vault")

      expect(open_groups).to eq([ "vault" ])
      expect(page).to have_css("[data-test='member-nav-tickets']", visible: :hidden)
    end

    it "keeps open the group of the page just reached" do
      sign_in_as(account_with(:owner))
      visit member_monitoring_error_groups_path
      expect(open_groups).to eq([ "observability" ])

      open("vault")
      visit member_tickets_path

      expect(page).to have_css("[data-test='member-nav-toggle-product'][aria-expanded='true']")
      expect(open_groups).to eq([ "product" ])
    end

    it "reopens the last group where no group is lit, only that one" do
      sign_in_as(account_with(:owner))
      visit root_path

      open("product")
      open("vault")
      visit root_path

      expect(page).to have_css("[data-test='member-nav-toggle-vault'][aria-expanded='true']")
      expect(open_groups).to eq([ "vault" ])
    end

    it "keeps everything closed on the next page after closing the last group" do
      sign_in_as(account_with(:owner))
      visit root_path

      open("vault")
      find("[data-test='member-nav-toggle-vault']").click
      expect(page).to have_css("[data-test='member-nav-toggle-vault'][aria-expanded='false']")

      visit root_path

      expect(page).to have_css("[data-test='member-nav']")
      expect(open_groups).to be_empty
    end

    it "opens the area overview from the group name" do
      sign_in_as(account_with(:owner))
      visit root_path

      find("[data-test='member-nav-observability-overview']").click

      expect(page).to have_current_path(member_observability_path)
    end
  end

  describe "compact mode", :js do
    it "narrows the sidebar to its icons and remembers it on the next page" do
      sign_in_as(account_with(:owner))
      visit root_path

      find("[data-test='member-nav-compact-toggle']").click
      expect(page).to have_css("#member-sidebar[data-compact]")
      expect(find("[data-test='member-nav-home']")[:title]).to eq(I18n.t("member.nav.home"))

      visit member_tickets_path

      expect(page).to have_css("#member-sidebar[data-compact]")
      expect(find("#member-sidebar").evaluate_script("this.getBoundingClientRect().width")).to be < 80

      find("[data-test='member-nav-compact-toggle']").click
      expect(page).to have_no_css("#member-sidebar[data-compact]")
    end

    # CYRA-909 — compact mode hid the leaves: a group's icon now shows them in a side flyout.
    def go_compact
      sign_in_as(account_with(:owner))
      visit root_path
      find("[data-test='member-nav-compact-toggle']").click
      expect(page).to have_css("#member-sidebar[data-compact]")
    end

    it "shows a group's entries beside its icon on hover" do
      go_compact

      find("[data-test='member-nav-observability-overview']").hover
      within("[data-test='member-nav-flyout-observability']") { click_link I18n.t("member.nav.errors") }

      expect(page).to have_current_path(member_monitoring_error_groups_path)
    end

    it "opens the entries on keyboard focus and closes them with Escape" do
      go_compact

      link = find("[data-test='member-nav-observability-overview']")
      link.execute_script("this.focus()")
      expect(page).to have_css("[data-test='member-nav-flyout-observability']", visible: :visible)

      link.send_keys(:escape)

      expect(page).to have_no_css("[data-test='member-nav-flyout-observability']", visible: :visible)
      expect(page.evaluate_script("document.activeElement.dataset.test")).to eq("member-nav-observability-overview")
    end

    it "never opens a flyout while the sidebar is wide" do
      sign_in_as(account_with(:owner))
      visit root_path

      find("[data-test='member-nav-observability-overview']").hover

      expect(page).to have_no_css("[data-test='member-nav-flyout-observability']", visible: :visible)
    end

    it "keeps the sections apart with a line" do
      go_compact

      expect(page).to have_css("[data-test='member-nav-section-divider']", visible: :visible, minimum: 2)
    end
  end
end
