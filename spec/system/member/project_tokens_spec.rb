# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member project tokens", type: :system do
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

  it "un admin crea un token e vede il segreto una sola volta" do
    env = create(:environment, organization: org, code: "production", label: "Production")
    project.environments << env
    sign_in_as(admin_account)

    visit member_project_tokens_path(project)
    find("[data-test='token-form-disclosure'] summary").click
    expect_test "token-form"
    fill_test "token-name", with: "Production SDK"
    click_on_test "token-create"
    conferma_azione_pericolosa

    expect_test "token-reveal"
    expect_test "token-secret"
    expect_test "token-project-id"
    expect(project.tokens.where(name: "Production SDK")).to exist

    # navigando di nuovo la index, il segreto non è più mostrato (reveal-once)
    visit member_project_tokens_path(project)
    expect(page).not_to have_css("[data-test='token-reveal']")
  end

  it "un admin revoca un token attivo" do
    env = create(:environment, organization: org, code: "production", label: "Production")
    project.environments << env
    token = Projects::Tokens::Issue.call(
      project:, name: "SDK", host: "bugs.example.com", environment: env
    ).value[:token]
    sign_in_as(admin_account)

    visit member_project_tokens_path(project)
    # CYRA-924 — the row button opens a <dialog> (no JS under rack_test): its red button is reached with visible: :all (F16).
    expect(page).to have_css("[data-test='token-revoke-#{token.id}'][data-action='ui--dialog#open']")
    find("[data-test='token-revoke-dialog-#{token.id}-confirm']", visible: :all).click

    expect(token.reload).to be_revoked
  end

  it "progetto senza environment dichiarati → avviso, niente form" do
    sign_in_as(admin_account)
    visit member_project_tokens_path(project)

    expect_test "token-no-environments"
    expect(page).not_to have_css("[data-test='token-form']")
  end
end
