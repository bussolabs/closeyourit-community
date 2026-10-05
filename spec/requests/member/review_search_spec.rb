# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Review search entry points", type: :request do
  let(:organization) { create(:organization) }
  let(:account) { create(:account) }

  before do
    create(:membership, account:, organization:, role: :member)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  it "matches list names and item titles without exposing private or cross-organization lists" do
    mine = shared = nil
    allow_n_plus_one do
      mine = create(:todo_list, account:, organization:, name: "Release notes")
      owner = create(:account)
      create(:membership, account: owner, organization:, role: :member)
      shared = create(:todo_list, account: owner, organization:, name: "Shared work")
      create(:todo_item, list: shared, title: "Release checklist")
      create(:todo_share, list: shared, account:)
      create(:todo_list, account: owner, organization:, name: "Release private")
      create(:todo_list, name: "Release elsewhere")
    end

    get member_todo_lists_path, params: { q: "release" }

    expect(response).to have_http_status(:ok)
    html = Capybara.string(response.body)
    expect(html).to have_link(mine.name, href: member_todo_list_path(mine))
    expect(html).to have_link(shared.name, href: member_todo_list_path(shared))
    expect(html).to have_no_text("Release private")
    expect(html).to have_no_text("Release elsewhere")
    expect(html).to have_no_css('[data-controller="todo-reorder"]')
    expect(html).to have_css('turbo-frame[target="_top"]')
  end

  it "treats wildcard characters literally and offers a way out of no results" do
    create(:todo_list, account:, organization:, name: "Release")
    get member_todo_lists_path, params: { q: "%_" }

    html = Capybara.string(response.body)
    expect(html).to have_css('[data-test="todo-lists-no-results"]')
    expect(html).to have_no_css('[data-test="todo-lists-empty"]')
    expect(html).to have_link(I18n.t("ui.no_results.reset_search"), href: member_todo_lists_path(ft: 1))
  end

  it "keeps the query when the last matching item is removed" do
    list = create(:todo_list, account:, organization:, name: "Release")
    item = create(:todo_item, list:, title: "Checklist")
    delete member_todo_list_item_path(list, item, from: "index", q: "Checklist")

    expect(response).to redirect_to(member_todo_lists_path(q: "Checklist"))
    follow_redirect!
    expect(Capybara.string(response.body)).to have_css('[data-test="todo-lists-no-results"]')
  end

  it "searches knowledge through the existing visible-pages endpoint with fresh filters" do
    get member_knowledge_root_path

    form = Nokogiri::HTML(response.body).at_css('[data-test="knowledge-overview-search"] form')
    expect(form["action"]).to eq(member_knowledge_pages_path)
    expect(form.at_css('input[name="q"]')).to be_present
    expect(form.at_css('input[name="ft"]')["value"]).to eq("1")
  end
end
