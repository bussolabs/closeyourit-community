# frozen_string_literal: true

require "rails_helper"

# CYRA-899 — the approvals board in a real browser: j/k move between rows, x ticks, a approves the
# focused row, and the chevron opens the preview under its row.
RSpec.describe "Approvals board — keyboard and preview", :js, type: :system do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:project) { create(:project, organization: org) }
  let(:review_status) { create(:ticket_status, :in_review, organization: org) }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    org.update_column(:cto_id, owner.id)
    create(:ticket_status, :done, organization: org)
  end

  def review_ticket(title)
    create(:ticket, organization: org, project:, status: review_status, reviewer: owner, title:)
  end

  def focused_test
    page.evaluate_script("document.activeElement.closest('tr')?.dataset.test")
  end

  def focused_text
    page.evaluate_script("document.activeElement.textContent")
  end

  it "moves with j and k, ticks with x and approves the focused row with a" do
    first = review_ticket("First to review").tap { |ticket| ticket.update_column(:updated_at, 2.hours.ago) }
    second = review_ticket("Second to review")
    sign_in_as(owner)
    visit member_home_approvals_path

    page.send_keys("j")
    expect(focused_test).to eq("approvals-board-row")
    expect(focused_text).to include(first.title)

    page.send_keys("j")
    expect(focused_text).to include(second.title)
    page.send_keys("k")
    expect(focused_text).to include(first.title)

    page.send_keys("x")
    expect(page).to have_css("[data-test='approvals-bulk-bar']", visible: true)

    page.send_keys("a")
    expect(page).to have_no_text(first.title)
    expect(page).to have_text(second.title)
    expect(first.reload.status.category).to eq("done")
    expect(second.reload.status.category).not_to eq("done")
  end

  it "opens the preview under the row and loads the request into it" do
    ticket = review_ticket("Rework the invoices")
    sign_in_as(owner)
    visit member_home_approvals_path

    expect(page).to have_no_css("[data-test='approvals-preview']")

    find("[data-test='approvals-row-preview-toggle']").click

    within("[data-test='approvals-row-preview']") do
      expect(page).to have_css("[data-test='approvals-detail-title']", text: ticket.title)
    end
  end

  # CYRA-904 — the whole row opens the preview; the ticket link keeps its own job.
  it "opens the preview when the row itself is clicked" do
    ticket = review_ticket("Click the row")
    sign_in_as(owner)
    visit member_home_approvals_path

    find("[data-test='approvals-board-project']").click

    within("[data-test='approvals-row-preview']") do
      expect(page).to have_css("[data-test='approvals-detail-title']", text: ticket.title)
    end
  end

  it "ticks every row without a report from the group header" do
    review_ticket("Bare one")
    review_ticket("Bare two")
    sign_in_as(owner)
    visit member_home_approvals_path

    find("[data-test='approvals-select-no-report']").click

    expect(page).to have_css("[data-test='approvals-bulk-bar']", visible: true, text: "2")
    expect(page).to have_no_css("[data-test='approvals-row-preview']", visible: true)
  end
end
