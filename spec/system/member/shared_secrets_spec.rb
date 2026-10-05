# frozen_string_literal: true

require "rails_helper"

# La matrice crea/edita via JS (sblocco riga + form associati per attributo `form=`), non esercitabile
# in rack_test: la LOGICA di create/upsert è coperta dai request spec. Qui si verifica il RENDERING
# della matrice — la riga di creazione è nascosta di default (rivelata dal pulsante «Aggiungi secret»),
# ha un campo per OGNI ambiente e NESSUN select — e le azioni a form nativo (elimina dal menu di riga).
# Il toggle mostra/annulla è client-side (Stimulus `secret-new-row`), non esercitabile in rack_test.
RSpec.describe "Member shared secrets", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization, name: "Demo") }
  let!(:env_prod) { create(:environment, organization: org, code: "production", label: "Production") }
  let!(:env_stg) { create(:environment, organization: org, code: "staging", label: "Staging") }

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  def owner_account
    account = create(:account)
    create(:membership, account:, organization: org, role: :owner)
    account
  end

  def shared_value(name, environment, value = "top-secret")
    Secrets::Shared::Save.call(organization: org, environment:, name:, value:).value
  end

  it "la riga di creazione è nascosta di default e ha un campo per ogni ambiente senza select" do
    sign_in_as(owner_account)
    visit member_shared_secrets_path

    # Il pulsante nell'header è visibile; la riga di creazione parte nascosta (rivelata via JS).
    expect_test "shared-secret-add"
    expect(page).to have_no_css("[data-test='shared-secret-new-row']")

    # Nel DOM la riga esiste (hidden) con un campo per OGNI ambiente e nessun select di ambiente.
    expect(page).to have_css("[data-test='shared-secret-new-row']", visible: :all)
    expect(page).to have_css("[data-test='shared-secret-new-name']", visible: :all)
    expect(page).to have_css("[data-test='shared-secret-new-value-production']", visible: :all)
    expect(page).to have_css("[data-test='shared-secret-new-value-staging']", visible: :all)
    within("[data-test='shared-secret-new-row']", visible: :all) { expect(page).not_to have_css("select") }
  end

  it "rende una riga per variabile mascherata e la copia; il valore NON è nel sorgente (CYRA-202)" do
    value = shared_value("API_KEY", env_prod, "postgres://x")
    sign_in_as(owner_account)

    visit member_shared_secrets_path
    expect_test "shared-secrets-matrix"
    expect_test "shared-secret-api_key"
    expect_test "shared-secret-copy-#{value.id}"
    # CYRA-202: il valore in chiaro non vive nel sorgente. Il textarea di editing parte vuoto: si
    # popola solo allo sblocco, via l'endpoint reveal.
    expect(page.body).not_to include("postgres://x")
    expect(find("[data-test='shared-secret-input-#{value.id}']", visible: :all).value).to eq("")
  end

  it "il menu di riga espone lo storico ed elimina la variabile" do
    shared_value("API_KEY", env_prod)
    sign_in_as(owner_account)

    visit member_shared_secrets_path
    expect(page).to have_css("[data-test='shared-secret-menu-api_key']", visible: :all)
    expect(page).to have_css("[data-test='shared-secret-delete-api_key']", visible: :all)
  end

  it "un owner elimina la variabile dal menu di riga" do
    variable = shared_value("API_KEY", env_prod).shared_variable
    sign_in_as(owner_account)

    visit member_shared_secrets_path
    # CYRA-924 — delete opens a <dialog> (no JS under rack_test): its red button is reached with visible: :all (F16).
    find("[data-test='shared-secret-delete-dialog-api_key-confirm']", visible: :all).click

    expect(Secrets::Shared::Variable.exists?(variable.id)).to be(false)
  end

  it "mostra l'attività audit dopo un salvataggio" do
    shared_value("API_KEY", env_prod)
    sign_in_as(owner_account)

    visit member_shared_secrets_path
    expect_test "shared-secrets-activity"
    expect_test "shared-secret-event"
  end
end
