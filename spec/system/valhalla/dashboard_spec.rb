# frozen_string_literal: true

require "rails_helper"

# The god dashboard in a real browser: the Access tabs, the page width, and a New in the modal.
RSpec.describe "Valhalla dashboard", :js, type: :system do
  let(:god) { create(:account, god: true, theme: "dark") }

  before do
    enable_two_factor!(god)
    visit login_path
    fill_test "login-email", with: god.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
    complete_two_factor_ui(god)
    # The login redirect must land before the next visit, or the session cookie is not set yet.
    expect(page).to have_css("#main-content")
    create(:ticket).update_columns(embedding: nil, created_at: 2.hours.ago)
  end

  it "shows one Access tab at a time and never scrolls sideways" do
    visit valhalla_root_path

    expect(page).to have_css("[data-test='valhalla-attention-drift-tickets']")
    expect(page).to have_css("[data-test='valhalla-dashboard-recent-sessions']", visible: :visible)
    expect(page).to have_css("[data-test='valhalla-dashboard-impersonations']", visible: :hidden)

    click_on_test "valhalla-access-tab-impersonations"

    expect(page).to have_css("[data-test='valhalla-dashboard-impersonations']", visible: :visible)
    expect(page).to have_css("[data-test='valhalla-dashboard-recent-sessions']", visible: :hidden)
    # Flush panels reach 1px past the frame on each side (T1), which clips them: more than that is a real overflow.
    overflow = page.evaluate_script("(() => { const m = document.querySelector('#main-content'); return m.scrollWidth - m.clientWidth })()")
    expect(overflow).to be <= 2
  end

  it "opens New organization in the modal, over the list" do
    visit valhalla_organizations_path
    click_on_test "valhalla-organization-new"

    expect(page).to have_css("dialog[data-test='member-modal'][open] [data-test='valhalla-organization-form']")
    expect(page).to have_current_path(valhalla_organizations_path)
  end
end
