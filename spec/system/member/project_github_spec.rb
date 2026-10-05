# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member project GitHub", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization, name: "Demo") }
  let(:project) { create(:project, organization: org, name: "Storefront") }

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

  it "senza installazione mostra la guida e il link alle integrazioni" do
    sign_in_as(owner_account)

    visit member_project_github_path(project)

    expect_test "github-needs-installation"
    expect_test "github-go-integrations"
  end

  it "con repo agganciato mostra le impostazioni e permette di scollegare" do
    repo = create(:github_repository, :with_env_mapping,
                  project:, installation: create(:github_installation, organization: org))
    sign_in_as(owner_account)

    visit member_project_github_path(project)
    expect_test "github-toggles"
    expect(page).to have_content(repo.full_name)

    click_on_test "github-disconnect"

    expect(project.reload.github_repository).to be_nil
  end

  it "mostra il toggle sync_secrets e il bottone Sync now, e il Sync now enfila il job" do
    create(:github_repository, :with_env_mapping,
           project:, installation: create(:github_installation, organization: org), sync_secrets: true)
    # Il preflight (CYRA-522) valida gli slot PRIMA di accodare, e per farlo legge i file di
    # configurazione dal repo tramite la GitHub App: senza credenziali — cioè sempre, in test —
    # fallisce con R502-GITHUB-001 e il job non parte. Qui si verifica che il bottone accodi, non
    # come si valida: la validazione ha i suoi spec dedicati in spec/services/secrets/github/.
    allow(::Secrets::Github::Preflight).to receive(:call).and_return(Result.ok([]))
    sign_in_as(owner_account)

    visit member_project_github_path(project)
    expect_test "github-sync-secrets-toggle"

    expect { click_on_test "github-sync-now" }
      .to have_enqueued_job(Secrets::Github::SyncJob)
    expect(page).to have_current_path(member_project_github_path(project))
  end
end
