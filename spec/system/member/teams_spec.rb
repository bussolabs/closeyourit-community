# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member teams", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization, name: "Demo") }

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  def owner
    account = create(:account)
    create(:membership, account: account, organization: org, role: :owner)
    account
  end

  it "owner crea un team (nome) dal form" do
    sign_in_as(owner)
    visit new_member_team_path
    expect_test "team-form"
    fill_test "team-name", with: "Support"
    click_on_test "team-form-submit"
    conferma_azione_pericolosa

    expect(page).to have_current_path(member_teams_path)
    expect(Teams::Team.find_by(organization: org, name: "Support")).to be_present
  end

  it "la index mostra il team coi suoi ruoli e scope" do
    team = create(:team, organization: org, name: "Support")
    role = create(:role, organization: org, name: "Maintainer", color: "emerald")
    create(:team_role, team: team, role: role)
    project = create(:project, organization: org, name: "Payments API")
    create(:team_project_access, team: team, project: project)

    sign_in_as(owner)
    visit member_teams_path
    expect_test "teams-count-teams"
    expect_test "teams-row-#{team.id}"
    expect(page).to have_text("Support")
    expect(page).to have_text("Maintainer")
    expect(page).to have_text("Payments API")
  end

  it "il membro senza permesso non vede la voce Teams in sidebar" do
    member = create(:account)
    create(:membership, account: member, organization: org, role: :member)
    sign_in_as(member)
    visit root_path
    expect(page).not_to have_css("[data-test='member-nav-teams']")
  end
end
