# frozen_string_literal: true

require "rails_helper"

# CYRA-901 — the list's results live in a turbo-frame that advances the URL, while the Board | List
# switch sits outside it. The switch must carry the filters of the address as it is at click time.
RSpec.describe "Tickets view switch after an in-place search", type: :system, js: true do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:status) { create(:ticket_status, organization: org) }

  it "carries a search made inside the list frame to the board" do
    owner = create(:account)
    create(:membership, account: owner, organization: org, role: :owner)
    create(:ticket, organization: org, project: project, status: status, title: "Checkout stuck on Safari")
    sign_in_as(owner)

    visit list_member_tickets_path
    find("[data-test='tickets-search']").fill_in(with: "checkout")
    find("[data-test='tickets-search-submit']").click
    expect(page).to have_current_path(/q=checkout/)

    find("[data-test='tickets-toolbar-view-menu'] summary").click
    find("[data-test='tickets-view-board']").click

    expect(page).to have_current_path(/\A#{Regexp.escape(member_tickets_path)}\?.*q=checkout/)
    expect(page).to have_css("[data-test='tickets-view-board'][aria-current='true']", visible: :all)
  end
end
