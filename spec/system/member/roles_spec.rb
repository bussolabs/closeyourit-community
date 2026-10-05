# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member roles", type: :system do
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

  it "owner crea un ruolo con alcune chiavi" do
    sign_in_as(owner)
    visit new_member_role_path
    expect_test "role-form"

    fill_test "role-name", with: "Triager"
    find("[data-test='role-key-errors.triage']").check
    find("[data-test='role-key-errors.promote']").check
    click_on_test "role-form-submit"
    conferma_azione_pericolosa

    expect(page).to have_current_path(member_roles_path)
    role = Authorization::Role.find_by(organization: org, name: "Triager")
    expect(role.permission_keys).to contain_exactly("errors.triage", "errors.promote")
  end

  it "owner modifica un ruolo e riconcilia le chiavi" do
    role = create(:role, organization: org, name: "Old")
    create(:role_permission, role: role, permission_key: "tickets.edit")
    sign_in_as(owner)
    visit edit_member_role_path(role)

    fill_test "role-name", with: "Maintainer"
    find("[data-test='role-key-tickets.edit']").uncheck
    find("[data-test='role-key-tickets.assign']").check
    click_on_test "role-form-submit"
    conferma_azione_pericolosa

    expect(role.reload.name).to eq("Maintainer")
    expect(role.permission_keys).to contain_exactly("tickets.assign")
  end

  it "the index shows the count chip and no tips panel" do
    create(:role, organization: org, name: "Maintainer")
    sign_in_as(owner)
    visit member_roles_path
    expect_test "roles-count-roles"
    expect(page).to have_no_css("[data-test='member-roles-tips']")
  end

  it "il membro senza permesso non vede la voce Roles in sidebar" do
    member = create(:account)
    create(:membership, account: member, organization: org, role: :member)
    sign_in_as(member)
    visit root_path
    expect(page).not_to have_css("[data-test='member-nav-roles']")
  end
end
