# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member milestones", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization, name: "Demo") }
  let(:project) { create(:project, organization: org, name: "Storefront") }

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  def admin
    account = create(:account)
    create(:membership, account: account, organization: org, role: :owner)
    account
  end

  it "un admin crea una milestone dal progetto" do
    sign_in_as(admin)
    visit new_member_project_milestone_path(project)
    expect_test "milestone-form"

    fill_test "milestone-label", with: "v2.0"
    fill_test "milestone-code", with: "v2_0"
    click_on_test "milestone-submit"

    expect(project.milestones.find_by(code: "v2_0")).to be_present
    milestone = project.milestones.find_by(code: "v2_0")
    expect_test "milestone-row-#{milestone.id}"
  end

  it "dalla lista milestone si apre il dettaglio con avanzamento" do
    milestone = create(:milestone, project: project, label: "v2.0")
    done = create(:ticket_status, organization: org, category: :done)
    create(:ticket, organization: org, project: project, milestone: milestone, status: done, weight: 3)

    sign_in_as(admin)
    visit member_project_milestones_path(project)
    find("[data-test='milestone-link-#{milestone.id}']").click

    expect_test "milestone-header"
    expect_test "milestone-progress"
    expect(page).to have_css("[data-test='milestone-percent']", text: "100%")
  end

  it "il form ticket espone milestone e weight; il ticket li mostra" do
    milestone = create(:milestone, project: project, label: "v2.0")
    create(:ticket_status, organization: org)
    create(:ticket_priority, organization: org)
    sign_in_as(admin)
    visit new_member_ticket_path(project_id: project.id)

    expect_test "ticket-milestone-field"
    expect_test "ticket-weight"

    fill_test "ticket-title", with: "Checkout broken"
    fill_test "ticket-description", with: "proceeds to payment"
    fill_test "ticket-weight", with: "5"
    select "v2.0", from: "milestone_id"
    click_on_test "ticket-submit"

    # Sulla show milestone e peso vivono nel pannello Dettagli a destra (CYRA-65).
    expect_test "detail-milestone"
    expect_test "detail-weight"
    expect(page).to have_css("[data-test='member-ticket']")
    ticket = Ticketing::Ticket.find_by(title: "Checkout broken")
    expect(ticket.milestone).to eq(milestone)
    expect(ticket.weight).to eq(5)
  end
end
