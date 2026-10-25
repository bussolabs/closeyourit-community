# frozen_string_literal: true

require "rails_helper"

# Closing New Puck with Cancel left the keyboard focus at the top of the page («Skip to content»)
# instead of on the button that opened it. CYRA-1107
RSpec.describe "A dialog gives the focus back to its opener", :js, type: :system do
  let(:org) { create(:organization, name: "Demo") }
  let(:account) do
    create(:account).tap { |acc| create(:membership, account: acc, organization: org, role: :owner) }
  end

  def active_test = page.evaluate_script("document.activeElement.dataset.test")

  it "returns to New Puck after Cancel" do
    allow(Coworkers).to receive(:enabled?).and_return(true)
    sign_in_as(account)
    visit member_coworkers_path
    if page.has_css?("dialog#coworker-new[open]", wait: 1)
      within("dialog#coworker-new[open]") { click_on I18n.t("member.coworkers.cancel") }
    end

    find("[data-test='coworkers-new-puck']", match: :first).click
    within("dialog#coworker-new[open]") { click_on I18n.t("member.coworkers.cancel") }

    expect(page).to have_no_css("dialog#coworker-new[open]")
    expect(active_test).to eq("coworkers-new-puck")
  end
end
