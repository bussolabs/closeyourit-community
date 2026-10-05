# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Valhalla organizations", type: :system do
  before { driven_by(:rack_test) }

  def sign_in_as(account)
    # CYRA-170: un god deve avere il 2FA (obbligatorio per Valhalla). Lo attivo al volo e completo il
    # secondo fattore nella challenge; per un non-god complete_two_factor_ui è un no-op.
    enable_two_factor!(account) if account.god? && !account.otp_enabled?
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
    complete_two_factor_ui(account)
  end

  def kebab_action(name, action)
    within("tr", text: name) do
      find("[data-test='valhalla-organization-menu']", visible: :all).click
      find("[data-test='#{action}']", visible: :all).click
    end
  end

  let(:god) { create(:account, god: true) }

  before { sign_in_as(god) }

  it "il god crea un'organizzazione e ne vede il dettaglio" do
    visit valhalla_organizations_path
    expect_test "valhalla-organizations"

    click_on_test "valhalla-organization-new"
    fill_test "organization-name", with: "Acme Inc"
    fill_test "organization-owner-email", with: "owner@acme.test"
    click_on_test "valhalla-organization-submit"

    expect_test "valhalla-organization-show"
    expect(Organizations::Organization.find_by(slug: "acme-inc")).to be_present
  end

  it "rinomina un'organizzazione dalla pagina di edit" do
    organization = create(:organization, name: "Vecchio", slug: "vecchio")
    visit edit_valhalla_organization_path(organization)
    expect_test "valhalla-organization-form"

    fill_test "organization-name", with: "Nome Nuovo"
    click_on_test "valhalla-organization-submit"

    expect_test "valhalla-organization-show"
    expect(organization.reload.name).to eq("Nome Nuovo")
  end

  it "sospende un'organizzazione dal kebab" do
    organization = create(:organization, name: "Da Sospendere")
    visit valhalla_organizations_path

    kebab_action("Da Sospendere", "valhalla-organization-suspend")

    expect(page).to have_current_path(valhalla_organizations_path)
    expect(organization.reload).to be_suspended
  end

  it "elimina un'organizzazione dal kebab" do
    organization = create(:organization, name: "Da Eliminare")
    visit valhalla_organizations_path

    # CYRA-924 — delete opens a <dialog> (no JS under rack_test): its red button is reached with visible: :all (F16).
    find("[data-test='valhalla-organization-delete-dialog-#{organization.id}-confirm']", visible: :all).click

    expect(page).to have_current_path(valhalla_organizations_path)
    expect(Organizations::Organization).not_to exist(organization.id)
  end

  it "mostra l'empty state senza organizzazioni" do
    visit valhalla_organizations_path
    expect_test "valhalla-organizations-empty"
  end

  it "filtra l'elenco per stato sospeso e mostra il footer di paginazione" do
    create(:organization, name: "Attiva Uno", suspended_at: nil)
    create(:organization, name: "Attiva Due", suspended_at: nil)
    create(:organization, name: "Sospesa Uno", suspended_at: Time.current)

    visit valhalla_organizations_path
    expect(all("[data-test='valhalla-organization-row']").size).to eq(3)
    expect_test "valhalla-organizations-pagination"

    visit valhalla_organizations_path(status: [ "suspended" ])
    rows = all("[data-test='valhalla-organization-row']")
    expect(rows.size).to eq(1)
    expect(rows.first).to have_text("Sospesa Uno")
  end

  it "mostra il footer di paginazione dei membri nel dettaglio" do
    organization = create(:organization, name: "Con Membri")
    create(:membership, organization: organization)

    visit valhalla_organization_path(organization)
    expect_test "valhalla-org-members-pagination"
    expect_test "valhalla-org-members-toolbar"
  end

  it "il god entra nel workspace dell'org dal kebab e poi esce" do
    organization = create(:organization, name: "Workspace Org")
    create(:membership, organization: organization, account: create(:account), role: :owner)

    visit valhalla_organizations_path
    kebab_action("Workspace Org", "valhalla-organization-enter")
    confirm_impersonation_ui(god) # CYRA-719: entrare nel workspace passa dal secondo fattore

    expect_test "impersonation-banner"
    expect_test "member-org-switcher"
    expect(page).to have_text("Workspace Org")

    click_on_test "impersonation-exit"
    expect(page).to have_current_path(valhalla_root_path)
  end

  it "il god entra nel workspace dell'org dal dettaglio" do
    organization = create(:organization, name: "Detail Org")
    create(:membership, organization: organization, account: create(:account), role: :owner)

    visit valhalla_organization_path(organization)
    click_on_test "valhalla-organization-enter"
    confirm_impersonation_ui(god) # CYRA-719: entrare nel workspace passa dal secondo fattore

    expect_test "impersonation-banner"
    expect(page).to have_text("Detail Org")
  end
end
