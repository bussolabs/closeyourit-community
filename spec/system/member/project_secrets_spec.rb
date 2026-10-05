# frozen_string_literal: true

require "rails_helper"

# La matrice edita/crea via JS (sblocco riga + form associati per attributo `form=`), non esercitabile
# in rack_test: la LOGICA di create/upsert è coperta dai request spec. Qui si verifica il RENDERING
# della matrice — la riga di creazione è nascosta di default (rivelata dal pulsante «Aggiungi secret») —
# e le azioni con form nativo indipendente (elimina, rollback dallo storico). Il toggle mostra/annulla è
# client-side (native <dialog>), non esercitabile in rack_test.
RSpec.describe "Member project secrets", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization, name: "Demo") }
  let(:project) { create(:project, organization: org, name: "Storefront") }

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

  def declare_production
    env = create(:environment, organization: org, code: "production", label: "Production")
    project.environments << env
    env
  end

  it "cerca per nome e origine, mostra zero risultati e azzera i filtri" do
    env = declare_production
    shared = Secrets::Shared::Save.call(organization: org, environment: env, name: "ORG_ENDPOINT",
                                        value: "valore-condiviso-di-prova", enqueue_sync: false).value
    shared.delegations.create!(project:, local_name: "APP_ENDPOINT")
    create(:secret_variable, project:, organization: org, environment: env, name: "LOCAL_ONLY")
    sign_in_as(admin_account)
    visit member_project_secrets_path(project)

    fill_test "secrets-search", with: "app_"
    # Origin sits in the toolbar "+ Filters" menu: without JS its select stays in the form.
    find("select[name='origin']", visible: :all).find("option[value='shared']", visible: :all).select_option
    click_on_test "secrets-filter-apply"
    expect(page).to have_css("#secret-app_endpoint")
    expect(page).to have_no_css("#secret-local_only")

    fill_test "secrets-search", with: "NOT_FOUND"
    click_on_test "secrets-filter-apply"
    expect(page).to have_content(I18n.t("member.secrets.origins.no_match"))
    click_on_test "secrets-toolbar-reset"
    expect(page).to have_css("#secret-app_endpoint")
    expect(page).to have_css("#secret-local_only")
  end

  it "rende la matrice: una riga per nome, la cella mascherata e la copia; il valore NON è nel sorgente (CYRA-202)" do
    env = declare_production
    variable = Secrets::Variables::Set.call(project:, environment: env, name: "DATABASE_URL", value: "postgres://x").value
    sign_in_as(admin_account)

    visit member_project_secrets_path(project)
    expect_test "secrets-matrix"
    expect_test "secret-row"
    expect_test "secret-copy-#{variable.id}"
    # CYRA-202: il valore in chiaro non vive nel sorgente (chi lo aprisse lo leggerebbe senza sbloccare).
    # The edit dialog's field starts empty: it is filled on open, from the reveal endpoint.
    expect(page.body).not_to include("postgres://x")
    expect(find("[data-test='secret-input-#{variable.id}']", visible: :all).value).to eq("")
  end

  # CYRA-924 — C65: adding a secret opens a dialog; it starts closed.
  it "adds a secret from a dialog that starts closed, with a field for the declared environment" do
    declare_production
    sign_in_as(admin_account)

    visit member_project_secrets_path(project)
    expect_test "secret-add"
    expect(page).to have_no_css("dialog[data-test='secret-new-dialog'][open]", visible: :all)
    expect(page).to have_css("[data-test='secret-new-dialog'] [data-test='secret-new-name']", visible: :all)
    expect(page).to have_css("[data-test='secret-new-dialog'] [data-test='secret-new-value-production']", visible: :all)
  end

  it "il menu di cella espone storico ed elimina" do
    env = declare_production
    variable = Secrets::Variables::Set.call(project:, environment: env, name: "API_KEY", value: "v").value
    sign_in_as(admin_account)

    visit member_project_secrets_path(project)
    expect(page).to have_css("[data-test='secret-history-#{variable.id}']", visible: :all)
    expect(page).to have_css("[data-test='secret-delete-#{variable.id}']", visible: :all)
  end

  it "un admin elimina un secret dal menu di cella" do
    env = declare_production
    variable = Secrets::Variables::Set.call(project:, environment: env, name: "API_KEY", value: "v").value
    sign_in_as(admin_account)

    visit member_project_secrets_path(project)
    find("[data-test='secret-menu-#{variable.id}']", visible: :all).click
    find("[data-test='secret-delete-#{variable.id}']", visible: :all).click

    expect(Secrets::Variable.exists?(variable.id)).to be(false)
  end

  it "progetto senza environment dichiarati → avviso, niente matrice" do
    sign_in_as(admin_account)
    visit member_project_secrets_path(project)

    expect_test "secret-no-environments"
    expect(page).not_to have_css("[data-test='secrets-matrix']")
  end

  it "mostra l'attività audit dopo un set" do
    admin = admin_account
    env = declare_production
    Secrets::Variables::Set.call(project:, environment: env, name: "API_KEY", value: "v", actor: admin)
    sign_in_as(admin)

    visit member_project_secrets_path(project)
    expect_test "secrets-activity"
    expect_test "secret-event"
  end

  # CYRA-77 — the full access log, with its filters, is the Access log tab of the secrets pages.
  it "reaches the full access log from the Access log tab" do
    admin = admin_account
    env = declare_production
    secret = Secrets::Variables::Set.call(project:, environment: env, name: "API_KEY", value: "v", actor: admin).value
    Secrets::RecordEvent.call(action: "read", project:, environment: env, actor: admin,
                              name: secret.name, channel: "web")
    sign_in_as(admin)

    visit member_project_secrets_path(project)
    click_on_test "secrets-subnav-events"

    expect(page).to have_current_path(member_project_secret_events_path(project))
    expect_test "secret-audit-counts"
    expect_test "secret-audit-table"
    expect(find("[data-test='secret-audit-rows']").text).to include("API_KEY")
    # Il registro dice chi ha letto che cosa, mai il contenuto.
    expect(page.body).not_to include(">v<")
  end

  it "storico versioni: apre lo storico dal menu e fa rollback a una versione precedente" do
    env = declare_production
    secret = Secrets::Variables::Set.call(project:, environment: env, name: "API_KEY", value: "old").value
    Secrets::Variables::Set.call(project:, environment: env, name: "API_KEY", value: "new")
    sign_in_as(admin_account)

    visit member_project_secrets_path(project)
    find("[data-test='secret-menu-#{secret.id}']", visible: :all).click
    find("[data-test='secret-history-#{secret.id}']", visible: :all).click

    expect_test "versions-list"
    v1 = secret.versions.ordered.last
    find("[data-test='version-rollback-#{v1.id}']").click

    expect(secret.reload.value).to eq("old")
  end
end
