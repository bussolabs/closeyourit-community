# frozen_string_literal: true

require "rails_helper"

# DESIGN.md E24 — a page-level empty state reaches the bottom of the frame instead of floating as a
# short box under the header.
RSpec.describe "Member empty states fill the page", :js, type: :system do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    sign_in_as(owner)
  end

  def gap_to_frame(selector)
    page.evaluate_script(<<~JS)
      (() => {
        const el = document.querySelector(#{selector.to_json})
        const scroller = el.closest("[data-panel-edge]") || document.querySelector("#main-content")
        return Math.round(scroller.getBoundingClientRect().bottom - el.getBoundingClientRect().bottom)
      })()
    JS
  end

  it "stretches the empty state of a plain page down to the frame" do
    visit member_todo_lists_path

    expect(page).to have_css("[data-empty-fill]")
    wait_until("empty state reaches the frame") { gap_to_frame("[data-empty-fill]").abs <= 2 }
    page.save_screenshot(Rails.root.join("tmp/empty_fill.png").to_s) if ENV["EMPTY_SHOT"]
    expect(page.evaluate_script("document.querySelector('#main-content').scrollHeight - document.querySelector('#main-content').clientHeight")).to be <= 1
  end

  it "stretches it inside the Administration shell too" do
    visit member_teams_path

    expect(page).to have_css("[data-empty-fill]")
    wait_until("empty state reaches the frame") { gap_to_frame("[data-empty-fill]").abs <= 2 }
  end

  # DESIGN.md E22 — the created/updated strip closes the page: on a short page it sits on the frame.
  it "keeps the audit strip on the bottom of the frame on a short page" do
    page.current_window.resize_to(1440, 1300)
    visit member_project_path(create(:project, organization: org))

    expect(page).to have_css("[data-page-foot]")
    wait_until("audit strip reaches the frame") { gap_to_frame("[data-test='project-page-footer']").abs <= 2 }
    expect(page.evaluate_script("document.querySelector('#main-content').scrollHeight - document.querySelector('#main-content').clientHeight")).to be <= 1
  end
end
