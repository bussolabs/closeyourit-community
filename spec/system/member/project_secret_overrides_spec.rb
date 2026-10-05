# frozen_string_literal: true

require "rails_helper"

# CYRA-79 — il giro completo: chi gestisce il vault assegna un valore a UNA persona dalla pagina, e da
# quel momento quella persona lo riceve quando scarica i segreti (`cyi run`), mentre tutte le altre
# continuano a ricevere il valore standard.
RSpec.describe "Member project secret overrides", type: :system do
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

  # Una persona che i secret di questo progetto li può già leggere: è l'unica a cui si può assegnare
  # un valore su misura.
  def reader_account(name)
    account = create(:account, name: name)
    create(:membership, account: account, organization: org, role: :member)
    create(:project_membership, account: account, project: project)
    create(:account_permission, account: account, organization: org, permission_key: "secrets.read", effect: :allow)
    account
  end

  def declare_production
    env = create(:environment, organization: org, code: "production", label: "Production")
    project.environments << env
    env
  end

  it "l'admin assegna un valore a una persona, che poi lo riceve al posto di quello standard" do
    environment = declare_production
    Secrets::Variables::Set.call(project:, environment:, name: "DATABASE_URL", value: "standard")
    destinatario = reader_account("Ada Lettrice")
    altra_persona = reader_account("Bruno Lettore")
    sign_in_as(admin_account)

    visit member_project_secret_overrides_path(project)
    expect_test "secret-overrides-empty"
    click_on_test "secret-override-new"

    select "Ada Lettrice", from: "account_id"
    select "Production", from: "environment_id"
    fill_test "secret-override-name", with: "DATABASE_URL"
    fill_test "secret-override-value", with: "postgres://ada"
    click_on_test "secret-override-submit"
    conferma_azione_pericolosa

    # La lista mostra a chi è stato assegnato cosa, MAI il valore.
    expect_test "secret-override-row"
    expect(page).to have_text("Ada Lettrice")
    expect(page).to have_text("DATABASE_URL")
    expect(page.body).not_to include("postgres://ada")

    # E il giro si chiude dove conta: chi lo riceve legge il suo valore, gli altri lo standard.
    expect(Secrets::Bundle.call(project:, environment:, account: destinatario).value)
      .to eq({ "DATABASE_URL" => "postgres://ada" })
    expect(Secrets::Bundle.call(project:, environment:, account: altra_persona).value)
      .to eq({ "DATABASE_URL" => "standard" })
  end

  it "toglie il valore su misura e la persona torna a quello standard" do
    environment = declare_production
    Secrets::Variables::Set.call(project:, environment:, name: "DATABASE_URL", value: "standard")
    destinatario = reader_account("Ada Lettrice")
    admin = admin_account
    override = Secrets::Overrides::Set.call(project:, environment:, account: destinatario,
                                            name: "DATABASE_URL", value: "postgres://ada", actor: admin).value
    sign_in_as(admin)

    visit member_project_secret_overrides_path(project)
    click_on_test "secret-override-remove-#{override.id}"
    conferma_azione_pericolosa

    expect_test "secret-overrides-empty"
    expect(Secrets::Bundle.call(project:, environment:, account: destinatario).value)
      .to eq({ "DATABASE_URL" => "standard" })
  end
end
