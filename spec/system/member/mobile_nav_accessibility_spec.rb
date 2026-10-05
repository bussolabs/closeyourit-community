# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Drawer member accessibile", type: :system, js: true do
  let(:organization) { create(:organization, name: "Demo") }
  let(:owner) { create(:account) }

  before do
    create(:membership, account: owner, organization: organization, role: :owner)
    sign_in_as(owner)
    page.current_window.resize_to(390, 844)
    visit root_path
  end

  it "toglie il drawer chiuso dal focus e restituisce il focus al pulsante dopo Escape" do
    sidebar = find("#member-sidebar", visible: :all)
    toggle = find("[data-test='member-nav-toggle']")

    expect(page).to have_css("#member-sidebar[inert]", visible: :all)
    expect(sidebar["aria-hidden"]).to eq("true")

    toggle.click
    expect(page).to have_no_css("#member-sidebar[inert]", visible: :all)
    expect(sidebar["aria-hidden"]).to eq("false")
    expect(page.evaluate_script("document.activeElement.closest('#member-sidebar') !== null")).to be(true)

    page.send_keys(:escape)
    expect(page).to have_css("#member-sidebar[inert]", visible: :all)
    expect(sidebar["aria-hidden"]).to eq("true")
    expect(page.evaluate_script("document.activeElement.dataset.test")).to eq("member-nav-toggle")
  end
end
