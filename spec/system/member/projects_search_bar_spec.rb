# frozen_string_literal: true

require "rails_helper"

# CYRA-883 — the search bar of the projects list in a real browser: Enter searches, the ✕ empties the
# search (and the remembered filters with it), the view switch still works from inside the bar.
RSpec.describe "Projects — search bar", :js, type: :system do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    create(:project, organization: org, name: "Storefront")
    create(:project, organization: org, name: "Payments API")
    sign_in_as(owner)
    visit member_projects_path
  end

  it "searches on Enter and empties the search with the ✕" do
    fill_in "q", with: "Store"
    find("[data-test='projects-search']").send_keys(:enter)

    expect(page).to have_text("Storefront")
    expect(page).to have_no_text("Payments API")

    find("[data-test='projects-toolbar-search-clear']").click

    expect(page).to have_text("Payments API")
    expect(find("[data-test='projects-search']").value).to eq("")

    visit member_projects_path
    expect(page).to have_text("Payments API")
  end

  def open_view_menu = find("[data-test='projects-toolbar-view-menu'] summary").click

  # CYRA-924 — cards or table and the card order are View menu choices (C62), not bar buttons.
  it "offers both views in the View menu and hides the no-JS apply button, in both views" do
    open_view_menu
    expect(page).to have_css("[data-test='projects-view-cards']")
    expect(page).to have_css("[data-test='projects-view-table']")
    expect(page).to have_no_css("[data-test='projects-filter']")

    find("[data-test='projects-view-table']").click
    expect(page).to have_css("[data-test='projects-table']")

    open_view_menu
    expect(page).to have_css("[data-test='projects-view-cards']")
    expect(page).to have_no_css("[data-test='projects-filter']")
  end

  it "sorts the cards from the View menu" do
    create(:error_group, project: Projects::Project.find_by!(name: "Payments API"))
    visit member_projects_path

    open_view_menu
    find("[data-test='projects-sort--errors']").click

    expect(page).to have_current_path(/sort=-errors/)
    names = all("a[data-test^='project-card-'] .font-display").map(&:text)
    expect(names.first).to eq("Payments API")
  end

  it "switches to the table from the View menu" do
    open_view_menu
    find("[data-test='projects-view-table']").click

    expect(page).to have_css("[data-test='projects-table']")
  end
end
