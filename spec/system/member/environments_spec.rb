# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member environments", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization, name: "Demo") }

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  def admin_account
    account = create(:account)
    create(:membership, account: account, organization: org, role: :owner)
    account
  end

  it "un admin crea un environment dal form" do
    account = admin_account
    sign_in_as(account)
    visit new_member_environment_path
    expect_test "environment-form"

    fill_test "environment-label", with: "Production"
    fill_test "environment-code", with: "production"
    click_on_test "environment-submit"

    expect_test "flash-notice"
    expect_test "member-environment"
    expect(org.environments.where(code: "production")).to exist
  end

  it "un admin disattiva un environment esistente" do
    account = admin_account
    environment = create(:environment, organization: org, code: "staging", label: "Staging", active: true)
    sign_in_as(account)
    visit edit_member_environment_path(environment)
    uncheck_active = find("[data-test='environment-active'] input[type=checkbox]")
    uncheck_active.set(false)
    click_on_test "environment-submit"

    expect(environment.reload.active).to be(false)
  end

  it "un admin elimina un environment inutilizzata" do
    account = admin_account
    environment = create(:environment, organization: org, code: "development", label: "Development")
    sign_in_as(account)
    visit member_environments_path
    # Delete opens a <dialog> (no JS under rack_test): its confirm button is reached with visible: :all.
    find("[data-test='environment-delete-dialog-#{environment.id}-confirm']", visible: :all).click

    expect(org.environments.where(code: "development")).not_to exist
  end

  # Il widget select è JS-enhanced (hidden senza JS): si testa l'integrazione visitando con i query
  # param, non guidando il widget (convenzione forms-select).
  it "filtra gli environment per stato via query param" do
    sign_in_as(admin_account)
    create(:environment, organization: org, code: "production", label: "Production", active: true)
    create(:environment, organization: org, code: "staging", label: "Staging", active: false)

    visit member_environments_path(status: [ "false" ])

    expect(page).to have_css("[data-test='member-environment']", count: 1)
    # Scoped to the rows: the release notes panel can mention "Production" too.
    expect(page).to have_css("[data-test='member-environment']", text: "Staging")
    expect(page).not_to have_css("[data-test='member-environment']", text: "Production")
  end

  it "ricerca senza match mostra il box no-match (filtro azzerabile)" do
    sign_in_as(admin_account)
    create(:environment, organization: org, code: "production", label: "Production")

    visit member_environments_path(q: "zzzznope")

    expect_test "environments-no-match"
  end
end
