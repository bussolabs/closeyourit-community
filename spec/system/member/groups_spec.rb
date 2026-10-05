# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member groups", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization, name: "Demo") }

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

  it "un admin crea un gruppo" do
    sign_in_as(admin)
    visit new_member_group_path
    expect_test "group-form"

    fill_test "group-name", with: "DriverOne"
    click_on_test "group-submit"

    expect_test "flash-notice"
    expect(Projects::Group.where(name: "DriverOne", organization: org)).to exist
  end

  it "il form mostra il campo icona (picker + upload)" do
    sign_in_as(admin)
    visit new_member_group_path
    expect_test "group-icon"
    expect_test "group-icon-image"
  end

  it "shows the group icon in the list" do
    create(:group, organization: org, name: "Iconed", icon: "rocket")
    sign_in_as(admin)
    visit member_groups_path
    expect(page).to have_css("svg[data-icon='rocket']", visible: :all)
  end

  # CYRA-924 — no filters, so no Filters menu: the saved views live in the View menu.
  it "the search-only toolbar offers the saved views in the View menu" do
    create(:group, organization: org, name: "Suite")
    sign_in_as(admin)
    visit member_groups_path
    expect(page).to have_css("[data-test='groups-toolbar']")
    expect(page).to have_no_css("[data-test='groups-toolbar-filters-menu']")
    find("[data-test='groups-toolbar-view-menu'] summary").click
    expect(page).to have_css("[data-test='groups-toolbar-view-menu'] [data-test='saved-views']")
  end

  it "un admin elimina un gruppo dalla show; i progetti restano senza gruppo" do
    account = admin
    group = create(:group, organization: org, name: "Suite")
    project = create(:project, organization: org, group: group)
    sign_in_as(account)

    visit member_group_path(group)
    click_on_test "group-delete"

    expect(Projects::Group.exists?(group.id)).to be(false)
    expect(project.reload.group_id).to be_nil
  end

  it "un membro semplice senza permesso non vede la pagina gruppi (gate)" do
    member = create(:account)
    create(:membership, account: member, organization: org, role: :member)
    create(:group, organization: org, name: "Suite")
    sign_in_as(member)

    visit member_groups_path
    expect(page).not_to have_css("[data-test='member-groups']")
    expect(page).to have_current_path(root_path)
  end

  it "un membro con project_groups.view vede la lista in sola lettura (niente New group)" do
    member = create(:account)
    create(:membership, account: member, organization: org, role: :member)
    Authorization::SetAccountPermissions.call(
      organization: org, account: member, allow_keys: [ "project_groups.view" ], actor: admin
    )
    create(:group, organization: org, name: "Suite")
    sign_in_as(member)

    visit member_groups_path
    expect(page).to have_css("[data-test='member-groups']")
    expect(page).not_to have_css("[data-test='groups-new']")
  end
end
