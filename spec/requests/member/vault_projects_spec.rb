# frozen_string_literal: true

require "rails_helper"

# CYRA-404 — l'area dichiarava di raccogliere tutti i segreti in un posto solo, ma per vedere quelli
# di un progetto si finiva in un'altra parte del prodotto, perdendo il menu dei segreti; e la stessa
# anomalia si chiamava in due modi diversi nei due posti.
RSpec.describe "Member::VaultProjects (CYRA-404)", type: :request do
  let(:org) { create(:organization) }
  let(:owner) { create(:account) }
  let!(:project) { create(:project, organization: org, name: "Storefront") }

  before do
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  it "l'elenco dice quanti segreti, quante anomalie e quando è stato toccato" do
    environment = create(:environment, organization: org)
    allow_n_plus_one do
      create(:project_environment, project: project, environment: environment)
      create(:secret_variable, project: project, environment: environment, name: "API_KEY")
    end

    get member_vault_projects_path

    doc = Nokogiri::HTML(response.body)
    expect(doc.at_css("[data-test='vault-projects-table']")).to be_present
    expect(doc.at_css("[data-test='vault-project-secrets-#{project.id}']").text.strip).to eq("1")
    expect(doc.at_css("[data-test='vault-project-last-change-#{project.id}']").text.strip).not_to eq("—")
  end

  # F162, F165 — C1, C4: the list has a search by project and a "with anomalies" filter.
  it "searches the projects by name or key" do
    other = create(:project, organization: org, name: "Backoffice")

    get member_vault_projects_path, params: { q: "store" }

    expect(response.body).to include('data-test="vault-projects-search"')
    expect(response.body).to include("vault-project-row-#{project.id}")
    expect(response.body).not_to include("vault-project-row-#{other.id}")
  end

  it "keeps only the projects with anomalies, and says so when none matches" do
    get member_vault_projects_path, params: { health: "anomalies" }

    expect(response.body).to include('data-test="vault-projects-filter-health"')
    expect(response.body).not_to include("vault-project-row-#{project.id}")
    expect(response.body).to include('data-test="vault-projects-no-match"')
  end

  it "sotto il titolo i conteggi: progetti, segreti e anomalie" do
    environment = create(:environment, organization: org)
    allow_n_plus_one do
      create(:project_environment, project: project, environment: environment)
      create(:secret_variable, project: project, environment: environment, name: "API_KEY")
    end

    get member_vault_projects_path

    counts = Nokogiri::HTML(response.body).at_css("[data-test='vault-projects-counts']")
    expect(counts.at_css("[data-test='vault-projects-stat-projects']").text).to include("1")
    expect(counts.at_css("[data-test='vault-projects-stat-secrets']").text).to include("1")
    expect(counts.at_css("[data-test='vault-projects-stat-anomalies']")).to be_present
  end

  it "da ogni riga si apre la tabella dei segreti di quel progetto" do
    get member_vault_projects_path

    link = Nokogiri::HTML(response.body).at_css("[data-test='vault-project-link-#{project.id}']")
    expect(link["href"]).to eq(member_project_secrets_path(project))
  end

  it "la tabella dei segreti resta dentro l'area dei segreti, col suo menu" do
    get member_project_secrets_path(project)

    doc = Nokogiri::HTML(response.body)
    # La sidebar della verticale Vault: se fossimo usciti dall'area, questa voce non ci sarebbe.
    expect(doc.at_css("[data-test='member-nav-vault-attention']")).to be_present
  end

  it "l'anomalia ha un nome solo in tutto il prodotto" do
    expect(I18n.t("member.secrets.counts.anomalies", count: 2).capitalize).to eq(I18n.t("member.vault.projects.col_anomalies"))
  end
end
