# frozen_string_literal: true

require "rails_helper"

# CYRA-911 — Administration is one sidebar entry; its pages carry their own section list on the left.
RSpec.describe "Member administration shell", type: :request do
  let(:org) { create(:organization) }

  def account_with(role)
    account = create(:account)
    create(:membership, account: account, organization: org, role: role)
    account
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def doc = Nokogiri::HTML(response.body)
  def sidebar = doc.at_css("#member-sidebar")
  def admin_nav = doc.at_css("[data-test='admin-nav']")

  context "as an owner" do
    before { sign_in(account_with(:owner)) }

    it "shows Administration in the sidebar as one entry, without the dropdown" do
      get member_members_path

      entry = sidebar.at_css("[data-test='member-nav-settings']")
      expect(entry.text.strip).to eq(I18n.t("member.nav.group_settings"))
      expect(entry["aria-current"]).to eq("page")
      expect(entry["href"]).to eq(member_members_path)
      expect(sidebar.at_css("[data-test='member-nav-toggle-settings']")).to be_nil
      expect(sidebar.at_css("[data-test='member-nav-members']")).to be_nil
    end

    it "lists the sections on the left, grouped, with the open one highlighted" do
      get member_members_path

      expect(admin_nav.at_css("[data-test='member-nav-members']")["aria-current"]).to eq("page")
      expect(admin_nav.at_css("[data-test='member-nav-service-accounts']")["aria-current"]).to be_nil
      expect(admin_nav.text).not_to include(I18n.t("member.nav.overview"))
      expect(admin_nav.css("[data-test^='admin-nav-section-']").map { |s| s["data-test"] })
        .to eq(%w[admin-nav-section-people admin-nav-section-projects admin-nav-section-organization])
    end

    it "wraps the detail pages of the area too" do
      get new_member_service_account_path
      expect(admin_nav.at_css("[data-test='member-nav-service-accounts']")["aria-current"]).to eq("page")
    end

    it "leaves pages outside the area alone" do
      get member_tickets_path

      expect(doc.at_css("[data-test='admin-shell']")).to be_nil
      expect(sidebar.at_css("[data-test='member-nav-settings']")["aria-current"]).to be_nil
    end
  end

  it "lists only the sections the account can open, and no empty group" do
    account = account_with(:member)
    Authorization::SetAccountPermissions.call(organization: org, account: account, allow_keys: [ "members.view" ],
                                              actor: account_with(:owner))
    sign_in(account)

    get member_members_path

    expect(admin_nav.css("a[data-test^='member-nav-']").map { |a| a["data-test"] }).to eq(%w[member-nav-members])
    expect(admin_nav.css("[data-test^='admin-nav-section-']").map { |s| s["data-test"] }).to eq(%w[admin-nav-section-people])
  end
end
