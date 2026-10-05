# frozen_string_literal: true

require "rails_helper"

# CYRA-883 — the member shell ends with a micro footer: the shared publisher credit and the privacy link.
RSpec.describe "Member shell footer", type: :request do
  before do
    org = create(:organization)
    owner = create(:account)
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
    get member_projects_path
  end

  it "renders the publisher credit and the privacy link below the content" do
    footer = Nokogiri::HTML(response.body).at_css("[data-test='member-footer']")

    expect(footer).to be_present
    expect(footer.at_css("[data-test='publisher-credit']")).to be_present
    expect(footer.at_css("a[href='#{privacy_path}']")).to be_present
  end

  it "spans the full width, credit on the left and the version on the right" do
    footer = Nokogiri::HTML(response.body).at_css("[data-test='member-footer']")

    expect(footer["class"]).to include("justify-between")
    expect(footer["class"]).not_to include("text-center")
    expect(footer.at_css("[data-test='footer-version'][data-action~='ui--dialog#open']")).to be_present
  end

  it "keeps the version in the sidebar on phones only" do
    html = Nokogiri::HTML(response.body)

    expect(html.at_css("#member-sidebar [data-test='sidebar-version']").parent["class"]).to include("md:hidden")
    expect(html.css("dialog[data-test='changelog-modal']").size).to eq(1)
  end

  it "offers the languages in a menu next to support, saved on the account, and marks the one in use" do
    footer = Nokogiri::HTML(response.body).at_css("[data-test='member-footer']")
    menu = footer.at_css("[data-test='footer-actions'] details[data-controller~='ui--row-menu']")

    expect(menu.at_css("summary[data-test='footer-locale']").text.squish)
      .to eq(I18n.t("member.preferences.language_options.en", locale: :en))
    expect(menu.at_css("[data-test='footer-locale-en'][aria-current='true']")).to be_present
    other = menu.at_css("form[action='#{member_preferences_path}']:has([data-test='footer-locale-it'])")
    expect(other.at_css("input[name='_method'][value='patch']")).to be_present
    expect(other.at_css("input[name='locale'][value='it']")).to be_present
    expect(other.at_css("[data-test='footer-locale-it']")["aria-current"]).to be_nil
  end

  it "groups support and the version as buttons on the right" do
    actions = Nokogiri::HTML(response.body).at_css("[data-test='member-footer'] [data-test='footer-actions']")

    expect(actions.at_css("button[data-test='footer-support']")).to be_present
    expect(actions.at_css("button[data-test='footer-version']")).to be_present
  end

  it "moves Guides to the footer buttons from md up, and keeps the drawer entry for phones" do
    html = Nokogiri::HTML(response.body)

    expect(html.at_css("[data-test='footer-actions'] a[data-test='footer-guides']")["href"]).to eq(member_guides_path)
    expect(html.at_css("#member-sidebar [data-test='member-nav-guides']").parent["class"]).to include("md:hidden")
  end

  it "says nothing about support requests when none is open" do
    expect(Nokogiri::HTML(response.body).at_css("[data-test='footer-support-open']")).to be_nil
  end

  it "says how many of the person's support requests are still open, linking to the list" do
    account = Accounts::Account.order(:created_at).last
    organization = account.memberships.first.organization
    2.times { Support::Request.create!(account:, organization:, body: "Still open") }
    Support::Request.create!(account:, organization:, body: "Taken care of", handled_at: Time.current)
    Support::Request.create!(account: create(:account), organization:, body: "Someone else's")

    get member_projects_path
    open = Nokogiri::HTML(response.body).at_css("[data-test='member-footer'] a[data-test='footer-support-open']")

    expect(open["href"]).to eq(member_support_requests_path)
    expect(open.text.squish).to eq(I18n.t("member.support.footer_open", count: 2))
  end

  it "signals the current release until the person has seen it" do
    account = Accounts::Account.order(:created_at).last
    expect(Nokogiri::HTML(response.body).at_css("[data-test='footer-version-new']")).to be_present

    account.update!(dismissed_notices: [ "release:#{Changelog.current.label}" ])
    get member_projects_path

    expect(Nokogiri::HTML(response.body).at_css("[data-test='footer-version-new']")).to be_nil
  end

  it "keeps the sidebar menu where it was when an entry opens the next page" do
    nav = Nokogiri::HTML(response.body).at_css("[data-test='member-nav']")

    expect(nav["data-controller"].split).to include("ui--keep-scroll")
    expect(nav["data-ui--keep-scroll-key-value"]).to eq("sidebar")
    expect(nav["data-action"]).to include("scroll->ui--keep-scroll#save")
  end
end
