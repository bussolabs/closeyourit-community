# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member uptime groups", type: :system do
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

  def uptime_capable_project
    create(:project, organization: org).tap do |p|
      p.project_platforms.create!(platform: create(:platform, :uptime_capable, organization: org))
    end
  end

  it "un owner crea un gruppo uptime dal form" do
    sign_in_as(owner)
    visit new_member_monitoring_uptime_group_path
    expect_test "uptime-group-form"

    fill_test "uptime-group-name", with: "Servizi Critici"
    click_on_test "uptime-group-submit"
    conferma_azione_pericolosa

    expect_test "flash-notice"
    expect(Uptime::Group.where(name: "Servizi Critici", organization: org)).to exist
  end

  it "il form mostra il campo icona (picker + upload) e la descrizione" do
    sign_in_as(owner)
    visit new_member_monitoring_uptime_group_path
    expect_test "uptime-group-icon"
    expect_test "uptime-group-icon-image"
    expect_test "uptime-group-description"
  end

  it "shows the group icon in the list" do
    create(:uptime_group, organization: org, name: "Iconed", icon: "rocket")
    sign_in_as(owner)
    visit member_monitoring_uptime_groups_path
    expect(page).to have_css("svg[data-icon='rocket']")
  end

  it "un owner modifica il nome di un gruppo" do
    group = create(:uptime_group, organization: org, name: "Vecchio")
    sign_in_as(owner)
    visit edit_member_monitoring_uptime_group_path(group)
    fill_test "uptime-group-name", with: "Nuovo"
    click_on_test "uptime-group-submit"
    conferma_azione_pericolosa
    expect(group.reload.name).to eq("Nuovo")
  end

  it "un owner elimina un gruppo dalla show; i monitor restano senza gruppo" do
    account = owner
    group = create(:uptime_group, organization: org, name: "Da eliminare")
    monitor = create(:uptime_monitor, group: group, project: uptime_capable_project)
    sign_in_as(account)

    visit member_monitoring_uptime_group_path(group)
    click_on_test "uptime-group-delete"
    conferma_azione_pericolosa

    expect(Uptime::Group.exists?(group.id)).to be(false)
    expect(monitor.reload.group_id).to be_nil
  end

  it "la show elenca i monitor del gruppo con link al monitor" do
    group = create(:uptime_group, organization: org, name: "Core")
    monitor = create(:uptime_monitor, group: group, project: uptime_capable_project)
    sign_in_as(owner)
    visit member_monitoring_uptime_group_path(group)
    expect(page).to have_css("[data-test='uptime-group-monitor-#{monitor.id}']")
  end

  it "il form del monitor mostra il selettore gruppo con i gruppi disponibili" do
    group = create(:uptime_group, organization: org, name: "API pubbliche")
    uptime_capable_project
    sign_in_as(owner)
    visit new_member_monitoring_monitor_path
    expect_test "monitor-group-field"
    expect(page).to have_content("API pubbliche")
  end

  it "dalla pagina Uptime il bottone Groups porta alla lista gruppi" do
    sign_in_as(owner)
    visit member_monitoring_monitors_path
    click_on_test "monitors-groups"
    expect(page).to have_current_path(member_monitoring_uptime_groups_path)
  end

  it "un membro semplice senza permesso non vede la pagina gruppi (gate)" do
    member = create(:account)
    create(:membership, account: member, organization: org, role: :member)
    sign_in_as(member)
    visit member_monitoring_uptime_groups_path
    expect(page).to have_current_path(root_path)
  end
end
