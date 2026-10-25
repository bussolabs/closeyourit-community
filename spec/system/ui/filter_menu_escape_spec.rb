# frozen_string_literal: true

require "rails_helper"

# Escape left the toolbar «Filters» menu open, and a filter panel too once an option was picked
# with the mouse: only a click outside closed them. CYRA-1103
RSpec.describe "Toolbar filters close with Escape", :js, type: :system do
  let(:org) { create(:organization, name: "Demo") }
  let!(:project) { create(:project, organization: org, name: "Storefront", key: "STR") }
  let(:account) do
    create(:account).tap { |acc| create(:membership, account: acc, organization: org, role: :owner) }
  end

  before do
    sign_in_as(account)
    visit list_member_tickets_path(ft: 1)
  end

  it "closes the Filters menu and gives the focus back to its button" do
    button = find("[data-test='tickets-toolbar-filters-menu']")
    button.click
    expect(button["aria-expanded"]).to eq("true")

    page.send_keys(:escape)

    expect(button["aria-expanded"]).to eq("false")
    expect(page.evaluate_script("document.activeElement.dataset.test")).to eq("tickets-toolbar-filters-menu")
  end

  it "closes a filter panel after an option was picked with the mouse" do
    find("[data-test='tickets-toolbar-filters-menu']").click
    find("[data-test='filter-menu-kind']").click
    combo = find("select[data-test='filter-kind']", visible: :all).find(:xpath, "..")
    combo.find("[role='option']", text: "Bug", visible: :all).click
    trigger = combo.find("button[aria-haspopup='listbox']")
    expect(trigger["aria-expanded"]).to eq("true")

    page.send_keys(:escape)

    expect(trigger["aria-expanded"]).to eq("false")
  end
end
