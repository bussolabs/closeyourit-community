# frozen_string_literal: true

require "rails_helper"

# A floating notice sat over the last rows and controls of the page, with no way to scroll them out
# from under it. The content now keeps room at its end as tall as the notices. CYRA-1105
RSpec.describe "Floating notices leave room at the end of the content", :js, type: :system do
  let(:org) { create(:organization, name: "Demo") }
  let(:account) do
    create(:account).tap { |acc| create(:membership, account: acc, organization: org, role: :owner) }
  end

  # The part of the page that scrolls: the Administration shell scrolls its own column.
  def bottom_padding = page.evaluate_script(<<~JS)
    Math.max(...[document.getElementById("main-content"), ...document.querySelectorAll("#main-content [data-panel-edge]")]
      .map((el) => parseFloat(getComputedStyle(el).paddingBottom) || 0))
  JS
  def notice_height = page.evaluate_script("document.querySelector('[data-test=floating-notices]').getBoundingClientRect().height")

  it "leaves the layout of a page that does not scroll alone" do
    sign_in_as(account)
    page.current_window.resize_to(1440, 2400)
    visit member_platforms_path
    expect(page).to have_css("[data-test='platforms-intro']")

    expect(bottom_padding).to be < notice_height
  end

  it "keeps room below the content while the notice is open, and gives it back once closed" do
    create_list(:platform, 12, organization: org)
    sign_in_as(account)
    page.current_window.resize_to(1440, 500)
    visit member_platforms_path
    expect(page).to have_css("[data-test='platforms-intro']")

    height = notice_height
    expect(bottom_padding).to be >= height

    find("[data-test='platforms-intro-dismiss']").click
    expect(page).to have_no_css("[data-test='platforms-intro']")
    wait_until("room given back") { bottom_padding < height }
  end
end
