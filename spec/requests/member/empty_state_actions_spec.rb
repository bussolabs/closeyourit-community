# frozen_string_literal: true

require "rails_helper"

# G1 — an empty page offers its first step where the person is reading, not only in the header.
RSpec.describe "Member empty states offer the first step", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }

  before do
    create(:membership, account: owner, organization: organization, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  def empty_action(path, empty:, action:)
    get path
    expect(response).to have_http_status(:ok)
    Capybara.string(response.body).find("[data-test='#{empty}'] [data-test='#{action}']")
  end

  it "to-do lists: New list opens the same dialog as the header button" do
    button = empty_action(member_todo_lists_path, empty: "todo-lists-empty", action: "todo-lists-empty-new")
    expect(button[:href]).to eq(new_member_todo_list_path)
  end

  it "collections: New collection" do
    button = empty_action(member_knowledge_books_path, empty: "knowledge-books-empty", action: "knowledge-books-empty-new")
    expect(button[:href]).to eq(new_member_knowledge_book_path)
  end

  it "datasets: New dataset sits beside the guide" do
    create(:project, organization: organization)
    button = empty_action(member_datasets_path, empty: "datasets-empty", action: "datasets-empty-new")
    expect(button[:href]).to eq(new_member_dataset_path)
  end

  it "delivery channels: New channel" do
    button = empty_action(member_alerting_channels_path, empty: "alerting-channels-empty", action: "alerting-channels-empty-new")
    expect(button[:href]).to eq(new_member_alerting_channel_path)
  end

  { "checked sites" => [ :member_monitoring_seo_sites_path, "seo-sites-empty" ],
    "findings" => [ :member_monitoring_seo_index_path, "seo-empty" ],
    "analysed pages" => [ :pages_member_monitoring_seo_index_path, "seo-pages-empty" ] }.each do |page, (route, empty)|
    it "#{page}: Add site" do
      button = empty_action(public_send(route), empty: empty, action: "seo-empty-new-site")
      expect(button[:href]).to eq(new_member_monitoring_seo_site_path)
    end
  end

  # B1 — the three SEO pages share a header, but each line under the title says what that page holds.
  it "checked sites and analysed pages have their own subtitle" do
    get member_monitoring_seo_sites_path
    expect(response.body).to include(I18n.t("member.monitoring.seo_sites.help_title"))
    expect(response.body).not_to include(ERB::Util.html_escape(I18n.t("member.monitoring.seo.help_title")))
  end

  it "analysed pages says it lists the visited pages" do
    get pages_member_monitoring_seo_index_path
    expect(response.body).to include(I18n.t("member.monitoring.seo.pages_help_title"))
  end

  # G10 — an empty section says so in one line instead of leaving its title alone.
  it "organization secrets: Recent activity says when nothing happened yet" do
    get member_shared_secrets_path

    note = Capybara.string(response.body).find("[data-test='shared-secrets-activity'] [data-test='shared-secrets-activity-empty']")
    expect(note.text.strip).to eq(I18n.t("member.shared_secrets.activity_empty"))
  end

  it "organization secrets: Add secret shows the new row" do
    button = empty_action(member_shared_secrets_path, empty: "shared-secrets-empty", action: "shared-secret-empty-add")
    expect(button["data-action"]).to eq("secret-new-row#show")
  end
end
