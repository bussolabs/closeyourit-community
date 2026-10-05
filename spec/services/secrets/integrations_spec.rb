# frozen_string_literal: true

require "rails_helper"

# CYRA-430 — la panoramica del Vault deve dire quali collegamenti automatici sono davvero accesi e su
# quanti progetti. Un numero inventato è peggio di nessun numero: qui si verifica che i due conteggi
# contino solo ciò che è realmente successo, e che direnv — che vive sul computer di chi lavora e il
# sistema non può vedere — non ne abbia uno.
RSpec.describe Secrets::Integrations do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:other_project) { create(:project, organization: org) }

  subject(:integrations) do
    described_class.new(organization: org, visible_project_ids: [ project.id, other_project.id ])
  end

  describe "#github_projects_count" do
    it "conta i progetti che hanno già sincronizzato almeno un segreto" do
      repository = create(:github_repository, project: project)
      repository.update_column(:synced_secret_names, { "production" => %w[DATABASE_URL] })

      expect(integrations.github_projects_count).to eq(1)
    end

    it "un repo collegato ma senza nemmeno un segreto spinto non conta" do
      create(:github_repository, project: project)
      repo_svuotato = create(:github_repository, project: other_project)
      repo_svuotato.update_column(:synced_secret_names, { "production" => [] })

      expect(integrations.github_projects_count).to eq(0)
    end

    it "i progetti che non vedo non entrano nel conteggio" do
      invisibile = create(:project, organization: org)
      repository = create(:github_repository, project: invisibile)
      repository.update_column(:synced_secret_names, { "production" => %w[DATABASE_URL] })

      expect(integrations.github_projects_count).to eq(0)
    end
  end

  describe "#cli_projects_count" do
    it "conta i progetti in cui i segreti sono stati letti da riga di comando" do
      create(:secret_event, organization: org, project: project, action: "read", metadata: { count: 3 })

      expect(integrations.cli_projects_count).to eq(1)
    end

    it "una lettura fatta dalla pagina web non è una lettura da riga di comando" do
      create(:secret_event, organization: org, project: project, action: "read",
                            metadata: { count: 1, source: "web" })

      expect(integrations.cli_projects_count).to eq(0)
    end

    it "non conta due volte lo stesso progetto" do
      create_list(:secret_event, 2, organization: org, project: project, action: "read", metadata: { count: 1 })

      expect(integrations.cli_projects_count).to eq(1)
    end

    it "una lettura più vecchia della finestra non dice che il collegamento è ancora in uso" do
      evento = create(:secret_event, organization: org, project: project, action: "read", metadata: { count: 1 })
      evento.update_column(:created_at, (described_class::CLI_WINDOW + 1.day).ago)

      expect(integrations.cli_projects_count).to eq(0)
    end

    it "una modifica non è una lettura" do
      create(:secret_event, organization: org, project: project, action: "set", name: "DATABASE_URL")

      expect(integrations.cli_projects_count).to eq(0)
    end
  end

  # Il rischio dichiarato dal ticket: lo stato «attivo su N progetti» richiede un conteggio reale.
  # direnv si abilita nel `.envrc` sul computer di chi sviluppa e non lascia traccia nel prodotto.
  describe "#direnv_countable?" do
    it "direnv non ha un numero, perché il sistema non può conoscerlo" do
      expect(integrations.direnv_countable?).to be(false)
    end
  end
end
