# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Ricerca globale member", :js, type: :system do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let!(:project) { create(:project, organization: organization, name: "Apollo Control") }

  before do
    create(:membership, account: owner, organization: organization, role: :owner)
    sign_in_as(owner)
  end

  it "si apre dal comando desktop e aggiorna i risultati mentre si digita" do
    page.current_window.resize_to(1280, 900)
    visit root_path

    click_on_test "global-search-trigger-desktop"
    expect(page).to have_css("[data-test='global-search-dialog'][open]")
    fill_test "global-search-input", with: "Apollo"

    expect_test "global-search-result-project-#{project.id}"
  end

  # CYRA-900 — a modal in the middle of the page, Enter opens the first result, and the next time
  # the dialog opens that result is listed among the recents.
  it "opens centred as a modal, opens the first result with Enter and remembers it" do
    page.current_window.resize_to(1280, 900)
    visit root_path

    click_on_test "global-search-trigger-desktop"
    dialog = find("[data-test='global-search-dialog'][open]")
    expect(page.evaluate_script("document.querySelector('#member-global-search').matches(':modal')")).to be(true)
    box = page.evaluate_script("(() => { const r = document.querySelector('#member-global-search').getBoundingClientRect(); return [r.left, window.innerWidth - r.right] })()")
    expect((box[0] - box[1]).abs).to be < 2
    expect(dialog).to have_css("[data-test='global-search-legend']")

    fill_test "global-search-input", with: "Apollo"
    expect_test "global-search-result-project-#{project.id}"
    find("[data-test='global-search-input']").send_keys(:enter)
    expect(page).to have_current_path(member_project_path(project))

    click_on_test "global-search-trigger-desktop"
    expect(page).to have_css("[data-test='global-search-recents'] [data-test='global-search-recent']", text: "Apollo Control")
  end

  it "keeps the key legend fixed at the bottom while the results scroll" do
    create_list(:project, 12, organization: organization, name: "Apollo extra")
    page.current_window.resize_to(1280, 700)
    visit root_path

    click_on_test "global-search-trigger-desktop"
    fill_test "global-search-input", with: "Apollo"
    expect_test "global-search-see-all-projects"
    page.execute_script("document.querySelector('#member-global-search .overflow-y-auto').scrollTop = 10000")

    inside = page.evaluate_script(<<~JS)
      (() => {
        const dialog = document.querySelector('#member-global-search').getBoundingClientRect()
        const legend = document.querySelector("[data-test='global-search-legend']").getBoundingClientRect()
        return legend.height > 0 && Math.abs(legend.bottom - (dialog.bottom - 1)) <= 1 && legend.bottom <= window.innerHeight
      })()
    JS
    expect(inside).to be(true)
  end

  it "keeps the key legend on the bottom edge before anything is typed" do
    page.current_window.resize_to(1280, 900)
    visit root_path

    click_on_test "global-search-trigger-desktop"
    gap = page.evaluate_script(<<~JS)
      (() => {
        const dialog = document.querySelector('#member-global-search').getBoundingClientRect()
        const legend = document.querySelector("[data-test='global-search-legend']").getBoundingClientRect()
        return Math.round(dialog.bottom - legend.bottom)
      })()
    JS
    expect(gap).to be <= 2
  end

  it "with Enter right after typing opens a result of the new search" do
    other = create(:project, organization: organization, name: "Zephyr Board")
    page.current_window.resize_to(1280, 900)
    visit root_path

    click_on_test "global-search-trigger-desktop"
    fill_test "global-search-input", with: "Apollo"
    expect_test "global-search-result-project-#{project.id}"
    input = find("[data-test='global-search-input']")
    input.set("Zephyr")
    input.send_keys(:enter)

    expect(page).to have_current_path(member_project_path(other))
  end

  it "su mobile occupa lo schermo e la lente non ha bordo" do
    page.current_window.resize_to(390, 844)
    visit root_path

    trigger = find("[data-test='global-search-trigger-mobile']")
    expect(trigger[:class]).to include("border-0")
    trigger.click

    expect(page).to have_css("[data-test='global-search-dialog'][open]")
    dialog = find("[data-test='global-search-dialog'][open]")
    expect(dialog[:class]).to include("h-[100dvh]")
    expect(dialog[:class]).to include("w-screen")
  end
end
