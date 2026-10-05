# frozen_string_literal: true

require "rails_helper"

# CYRA-777 — il giro intero, dalla riga in «Da sistemare» al valore che si è spostato davvero. Senza
# JavaScript (rack_test): la pagina di conferma è un modulo vero e il «Non proporre più» punta il
# modulo condiviso della pagina con `form=`, quindi il giro si prova così com'è — ed è anche la prova
# che quell'aggancio regge, verbo compreso.
RSpec.describe "Member vault — Valore in comune", type: :system do
  before { driven_by(:rack_test) }

  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let(:production) { create(:environment, organization: org, code: "production", label: "Production") }

  before { create(:membership, account: owner, organization: org, role: :owner) }

  def sign_in_as(account)
    visit login_path
    fill_test "login-email", with: account.email
    fill_test "login-password", with: "Secret123!"
    click_on_test "login-submit"
  end

  def progetto(nome)
    create(:project, organization: org, name: nome).tap { |project| project.environments << production }
  end

  let(:uno) { progetto("Alfa") }
  let(:due) { progetto("Beta") }

  def proposta
    Secrets::Variables::Set.call(project: uno, environment: production, name: "API_KEY", value: "valore-condiviso-lungo")
    Secrets::Variables::Set.call(project: due, environment: production, name: "CHIAVE_API", value: "valore-condiviso-lungo")
    Secrets::Consolidation::Refresh.call(organization: org)
    Secrets::Consolidation::Suggestion.last
  end

  it "dalla riga in «Da sistemare» si arriva alla proposta e si sposta il valore" do
    suggestion = proposta
    sign_in_as(owner)

    visit member_vault_attention_path
    click_on_test "vault-attention-consolidation-#{suggestion.id}"

    # La pagina dice cosa sparisce da ogni progetto e con che nome ciascuno continuerà a leggerlo.
    within_test("vault-consolidation-projects") do
      expect(page).to have_text("Alfa").and have_text("Beta")
      expect(page).to have_text("API_KEY").and have_text("CHIAVE_API")
    end
    expect(page.body).not_to include("valore-condiviso-lungo")

    click_on_test "vault-consolidation-promote"

    expect(page).to have_text(I18n.t("member.vault_consolidations.promoted"))
    expect(suggestion.reload).to be_status_promoted
    # Ogni progetto continua a leggere il valore col nome che aveva: nessuno ha dovuto toccare il
    # proprio codice per accettare.
    expect(Secrets::Bundle.call(project: uno, environment: production).value).to eq("API_KEY" => "valore-condiviso-lungo")
    expect(Secrets::Bundle.call(project: due, environment: production).value).to eq("CHIAVE_API" => "valore-condiviso-lungo")
  end

  it "«Non proporre più» archivia la proposta e la toglie dalla lista" do
    suggestion = proposta
    sign_in_as(owner)

    visit member_vault_consolidation_path(suggestion)
    click_on_test "vault-consolidation-dismiss"

    expect(page).to have_text(I18n.t("member.vault_consolidations.dismissed"))
    expect(suggestion.reload).to be_status_dismissed
    expect(page).to have_no_css("[data-test='vault-attention-consolidation-#{suggestion.id}']")
  end

  it "dalla pagina segreti del progetto il banner porta alla stessa proposta" do
    suggestion = proposta
    sign_in_as(owner)

    visit member_project_secrets_path(uno)
    # CYRA-842 — le proposte stanno in un gruppo ripiegato per nome: si apre, poi si sceglie l'ambiente.
    within_test("secrets-consolidation-banner") do
      click_on_test "secrets-consolidation-summary"
      find("[data-test='secrets-consolidation-group'] summary").click
      click_on_test "secrets-consolidation-link-#{suggestion.id}"
    end

    expect_test "vault-consolidation-header"
  end
end
