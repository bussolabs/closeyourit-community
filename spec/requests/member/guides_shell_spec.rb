# frozen_string_literal: true

require "rails_helper"

# The guides read like the Administration area: an index of every guide on the left, the open guide on
# the right, so moving from one guide to the next never goes back through a page of cards.
RSpec.describe "Member guides shell", type: :request do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }
  let(:doc) { Nokogiri::HTML(response.body) }

  before do
    create(:membership, account:, organization: org, role: :member)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def nav_links
    doc.css("[data-test='guides-nav'] a")
  end

  it "frames a guide with the index on the left and marks the open guide" do
    get member_guides_errors_path

    shell = doc.at_css("[data-test='guides-shell']")
    expect(shell.at_css("[data-test='guides-nav']")).to be_present
    expect(shell.at_css("[data-test='member-guide-errors'], [data-test^='member-guide']")).to be_present
    active = nav_links.select { |link| link["aria-current"] == "page" }.map { |link| link["data-test"] }
    expect(active).to eq(%w[member-guides-card-errors])
  end

  it "lists every guide once, the catalog first and the overview right after it" do
    get member_guides_errors_path

    tests = nav_links.map { |link| link["data-test"] }
    expect(tests.first(2)).to eq(%w[member-guides-card-catalog member-guides-card-overview])
    expect(tests.uniq.size).to eq(tests.size)
    expect(tests.size).to eq(39)
    expect(tests).to include("member-guides-card-installation", "member-guides-card-traces")
  end

  it "groups the index under headings" do
    get member_guides_errors_path

    expect(doc.css("[data-test^='guides-nav-section-']").size).to eq(7)
  end

  it "opens on the catalog of every space, with no page of cards" do
    get member_guides_path

    expect(doc.at_css("[data-test='guides-shell'] [data-test='member-guides-catalog']")).to be_present
    expect(doc.at_css("[data-test='member-guides-start-here']")).to be_nil
    active = nav_links.select { |link| link["aria-current"] == "page" }.map { |link| link["data-test"] }
    expect(active).to eq(%w[member-guides-card-catalog])
  end

  it "keeps the Administration shell off the guides" do
    get member_guides_errors_path

    expect(doc.at_css("[data-test='admin-shell']")).to be_nil
  end

  it "keeps the index where it was when a guide opens the next page" do
    get member_guides_errors_path

    aside = doc.at_css("[data-test='guides-shell'] aside")
    expect(aside["data-controller"]).to eq("ui--keep-scroll")
    expect(aside["data-ui--keep-scroll-key-value"]).to eq("guides")
  end

  # The way out of a guide (open the page it explains) sits in the header, where the eye starts,
  # never as a loose row after the last panel.
  %w[activity crons errors feature_matrix integrations knowledge logs overview performance permissions
     replays secrets servers structure ticket_lifecycle tickets uptime vault
     approvals datasets analytics].each do |slug|
    it "puts the #{slug} guide's button in the page header" do
      get public_send("member_guides_#{slug}_path")

      cta = doc.at_css("[data-test='member-guide-#{slug.dasherize}-cta']")
      expect(cta.ancestors("[data-controller~='ui--page-header']")).to be_present
    end
  end

  { "seo" => "guide-seo-open", "vulnerabilities" => "guide-vulnerabilities-open" }.each do |slug, test_id|
    it "puts the #{slug} guide's button in the page header" do
      get public_send("member_guides_#{slug}_path")

      expect(doc.at_css("[data-test='#{test_id}']").ancestors("[data-controller~='ui--page-header']")).to be_present
    end
  end
end
