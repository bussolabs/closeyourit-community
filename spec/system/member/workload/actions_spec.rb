# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member workload actions", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization, name: "Demo") }
  let(:team) { create(:team, organization: org, name: "Marketing") }
  let(:other_team) { create(:team, organization: org, name: "Sales") }

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  def member_account
    account = create(:account)
    create(:membership, account: account, organization: org, role: :member)
    create(:team_membership, team: team, account: account)
    account
  end

  it "vede la board del proprio team e non quella di altri team" do
    sign_in_as(member_account)
    mine = create(:workload_action, team: team, organization: org, title: "Fiera Marketing")
    theirs = create(:workload_action, team: other_team, organization: org, title: "Trattativa Sales")

    visit member_workload_actions_path

    expect_test "member-workload-board"
    expect(page).to have_css("[data-test='workload-board-column-planned']")
    expect(page).to have_text(mine.title)
    expect(page).not_to have_text(theirs.title)
  end

  it "the board shows no tip bubble and no tips panel" do
    sign_in_as(member_account)
    visit member_workload_actions_path

    expect(page).to have_no_css("[data-test='workload-board-header-title-tip']")
    expect(page).to have_no_css("[data-test='member-workload-board-tips']")
  end

  # Board: la toolbar filtri si applica in auto-submit via JS; sotto rack_test verifichiamo il
  # contratto server (toolbar renderizzata + filtro per param URL). Status è l'asse colonne → il
  # filtro board esposto è per team (qui), participant e has_ticket.
  it "rende la toolbar filtri sulla board e filtra per team via param URL" do
    account = member_account
    create(:team_membership, team: other_team, account: account)
    sign_in_as(account)
    here = create(:workload_action, team: team, organization: org, title: "Fiera del primo team")
    elsewhere = create(:workload_action, team: other_team, organization: org, title: "Trattativa altro team")

    visit member_workload_actions_path
    expect_test "workload-board-toolbar"

    visit member_workload_actions_path(team_id: [ team.id ])
    expect(page).to have_text(here.title)
    expect(page).not_to have_text(elsewhere.title)
  end

  it "filtra per stato via query param (il widget select è JS-enhanced)" do
    sign_in_as(member_account)
    planned = create(:workload_action, team: team, organization: org, title: "Pianificata", status: :planned)
    done = create(:workload_action, team: team, organization: org, title: "Completata", status: :done)

    visit list_member_workload_actions_path(status: [ "planned" ])

    expect(page).to have_text(planned.title)
    expect(page).not_to have_text(done.title)
  end

  it "apre il form di creazione" do
    sign_in_as(member_account)

    visit new_member_workload_action_path

    expect_test "workload-action-form"
  end

  it "modifica il titolo di una action" do
    sign_in_as(member_account)
    action = create(:workload_action, team: team, organization: org, title: "Titolo vecchio")

    visit edit_member_workload_action_path(action)
    fill_test "workload-action-title", with: "Titolo nuovo"
    click_on_test "workload-action-submit"

    expect(action.reload.title).to eq("Titolo nuovo")
  end

  it "elimina una action dalla show" do
    sign_in_as(member_account)
    action = create(:workload_action, team: team, organization: org)

    visit member_workload_action_path(action)
    click_on_test "workload-action-more-menu"
    click_on_test "workload-action-delete"
    expect_test "flash-notice"

    expect(Workload::Action.exists?(action.id)).to be(false)
  end

  it "mostra partecipanti e ticket collegato nella show" do
    account = member_account
    sign_in_as(account)
    action = create(:workload_action, :with_participants, :with_ticket, team: team, organization: org)

    visit member_workload_action_path(action)

    expect_test "workload-action-participants-card"
    expect_test "workload-action-ticket-card"
    expect(page).to have_text(action.ticket.code)
  end

  it "mostra 'genera ticket' solo per una action non collegata" do
    sign_in_as(member_account)
    unlinked = create(:workload_action, team: team, organization: org)

    visit member_workload_action_path(unlinked)

    expect_test "workload-action-promote"
  end
end
