# frozen_string_literal: true

require "rails_helper"

# CYRA-63: tab Environments — posto unico di gestione. Attiva/disattiva l'environment sul progetto e
# mostra i controlli tri-state solo sulle righe attive.
RSpec.describe "Member project environments — tab", type: :system do
  let(:org) { create(:organization, name: "Demo") }
  let(:project) { create(:project, organization: org, name: "Storefront", key: "STR") }
  let!(:env) { create(:environment, organization: org, code: "production", label: "Production") }

  def owner_account
    account = create(:account)
    create(:membership, account: account, organization: org, role: :owner)
    account
  end

  before { driven_by(:rack_test) }

  it "attiva e disattiva un environment sul progetto dai pulsanti della tabella" do
    sign_in_as(owner_account)

    visit member_project_environments_path(project)
    expect_test "project-environments-manage"

    # Environment non attivo → pulsante Attiva, nessun controllo tri-state.
    expect_test "project-environment-activate-#{env.id}"
    expect(page).to have_no_css("[data-test='env-cap-#{env.id}-servers']")

    click_on_test "project-environment-activate-#{env.id}"
    expect(project.environments.reload).to include(env)

    # Ora attivo → controlli tri-state visibili + pulsante Disattiva.
    expect_test "env-cap-#{env.id}-servers"
    expect_test "project-environment-deactivate-#{env.id}"

    click_on_test "project-environment-deactivate-#{env.id}"
    expect(project.environments.reload).not_to include(env)
  end

  it "la tab è raggiungibile dal link nell'header (manager)" do
    project.environments << env
    sign_in_as(owner_account)

    visit member_project_path(project)
    click_on_test "project-environments-link"

    expect(page).to have_current_path(member_project_environments_path(project))
    expect_test "project-environments-manage"
  end
end
