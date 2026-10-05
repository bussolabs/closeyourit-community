# frozen_string_literal: true

require "rails_helper"

# The milestone parts that need a browser: closed groups that open with a click and the Active switch.
# Gated by spec/support/js_system.rb (JS_SYSTEM_SPECS=1).
RSpec.describe "Member milestones in the browser", :js, type: :system do
  let(:org) { create(:organization) }
  let(:owner) do
    create(:account).tap { |a| create(:membership, account: a, organization: org, role: :owner) }
  end
  let(:project) { create(:project, organization: org) }

  it "opens the Inactive group with a click" do
    create(:milestone, project: project, label: "Live")
    old = create(:milestone, project: project, label: "Old", active: false)
    sign_in_as(owner)
    visit member_project_milestones_path(project)

    expect(page).to have_no_css("[data-test='milestone-row-#{old.id}']")
    find("[data-test='milestones-inactive-group-toggle']").click

    expect(page).to have_css("[data-test='milestone-row-#{old.id}']", text: "Old")
  end

  it "opens the Closed tickets group with a click" do
    milestone = create(:milestone, project: project)
    done = create(:ticket_status, organization: org, category: :done)
    closed = create(:ticket, organization: org, project: project, milestone: milestone, status: done)
    sign_in_as(owner)
    visit member_project_milestone_path(project, milestone)

    expect(page).to have_no_css("[data-test='milestone-ticket-#{closed.id}']")
    find("[data-test='milestone-tickets-closed-group-toggle']").click

    expect(page).to have_css("[data-test='milestone-ticket-#{closed.id}']")
  end

  it "switches a milestone off from Details without a reload" do
    milestone = create(:milestone, project: project, active: true)
    sign_in_as(owner)
    visit member_project_milestone_path(project, milestone)

    find("[data-test='milestone-active-toggle']").click

    expect(page).to have_css("[data-test='milestone-detail-status']", text: I18n.t("ui.switch.saved"))
    expect(milestone.reload.active).to be(false)
    expect(page).to have_current_path(member_project_milestone_path(project, milestone))
  end
end
