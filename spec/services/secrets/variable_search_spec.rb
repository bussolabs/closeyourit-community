# frozen_string_literal: true

require "rails_helper"

# Ricerca cross-progetto delle variabili segrete per NOME (CYRA-424): trasforma i match in una
# MATRICE progetto × ambiente, dove ogni riga è una coppia [nome, progetto] con una cella per ogni
# ambiente ATTIVO del progetto (presente/assente). Filtri (progetto, ambiente), ordinamento per
# occorrenze e paginazione. Le assenze sono calcolate sugli ambienti attivi del SINGOLO progetto,
# mai su un elenco fisso; non espone mai un valore.
RSpec.describe Secrets::VariableSearch do
  let(:org) { create(:organization) }
  let(:project_a) { create(:project, organization: org, name: "Progetto Alfa") }
  let(:project_b) { create(:project, organization: org, name: "Progetto Beta") }
  let(:production) { create(:environment, organization: org, code: "production", label: "Produzione", position: 0) }
  let(:staging) { create(:environment, organization: org, code: "staging", label: "Staging", position: 1) }
  let(:visible) { Projects::Project.where(organization: org) }

  before do
    project_a.environments << production
    project_a.environments << staging
    project_b.environments << production
  end

  def call(**overrides)
    described_class.call(projects: visible, query: "DATABASE", **overrides)
  end

  describe "variabili condivise delegate" do
    def delegate(name: "DATABASE_URL", environment: production, project: project_a, local_name: nil)
      value = Secrets::Shared::Save.call(organization: org, environment:, name:,
                                         value: "valore-di-prova-condiviso", enqueue_sync: false).value
      value.delegations.create!(project:, local_name:)
    end

    it "trova una variabile disponibile solo tramite delega" do
      delegate

      result = call

      expect(result.total_rows).to eq(1)
      expect(result.rows.first.cell_for(production).present).to be(true)
      expect(result.rows.first.cell_for(staging).present).to be(false)
      expect(result.project_options).to eq([ [ project_a.name, project_a.id ] ])
    end

    it "cerca il nome effettivo del progetto rispettando alias, maiuscole e underscore letterali" do
      delegate(name: "ORG_DATABASE", local_name: "CUSTOM_DATABASE")

      expect(call(query: "custom_data").rows.map(&:name)).to eq([ "CUSTOM_DATABASE" ])
      expect(call(query: "ORG_DATABASE").rows).to be_empty
      expect(call(query: "CUSTOM%DATA").rows).to be_empty
      expect(call(query: "CUSTOM__DATABASE").rows).to be_empty
    end

    it "unisce presenze locali e delegate in ambienti diversi senza duplicare la riga" do
      delegate
      create(:secret_variable, project: project_a, organization: org, environment: staging, name: "DATABASE_URL")

      result = call

      expect(result.total_rows).to eq(1)
      expect(result.rows.first.present_count).to eq(2)
      expect(result.total_absences).to eq(0)
      expect(call(environment_code: "staging").rows.first.present_count).to eq(1)
    end

    it "esclude deleghe di progetti fuori dal perimetro visibile anche dalle opzioni" do
      delegate(project: project_b)

      result = described_class.call(projects: visible.where(id: project_a.id), query: "DATABASE")

      expect(result.rows).to be_empty
      expect(result.project_options).to be_empty
      expect(result.environment_options).to be_empty
    end

    it "non attribuisce agli altri progetti una variabile condivisa senza delega" do
      delegate

      expect(call.rows.map(&:project)).to eq([ project_a ])
      expect(call(project_id: project_b.id).rows).to be_empty
    end

    it "non carica colonne cifrate per cercare i nomi" do
      delegate
      create(:secret_variable, project: project_a, organization: org, environment: staging, name: "DATABASE_URL")
      queries = []
      subscriber = ->(_name, _start, _finish, _id, payload) { queries << payload[:sql] }

      ActiveSupport::Notifications.subscribed(subscriber, "sql.active_record") { call }

      selections = queries.grep(/\ASELECT.*FROM "secrets_(variables|shared_delegations)"/i)
        .map { |sql| sql.split(/\bFROM\b/i).first }
      expect(selections.size).to eq(2)
      expect(selections.join(" ")).not_to match(/\*|[".]value[", ]|value_ciphertext/)
    end
  end

  describe "query vuota" do
    it "è blank e non produce righe" do
      result = described_class.call(projects: visible, query: "   ")

      expect(result).to be_blank
      expect(result.rows).to be_empty
      expect(result.total_rows).to eq(0)
    end
  end

  describe "matrice presenze/assenze (Scenario 2)" do
    it "una riga per [nome, progetto], con una cella per ogni ambiente attivo del progetto" do
      create(:secret_variable, project: project_a, environment: production, organization: org, name: "DATABASE_URL")

      result = call
      row = result.rows.find { |r| r.project == project_a && r.name == "DATABASE_URL" }

      expect(row).not_to be_nil
      expect(row.cells.map { |c| c.environment.code }).to contain_exactly("production", "staging")
    end

    it "segna presente l'ambiente in cui la variabile esiste e assente quello dove manca" do
      create(:secret_variable, project: project_a, environment: production, organization: org, name: "DATABASE_URL")

      row = call.rows.find { |r| r.project == project_a }

      expect(row.cell_for(production).present).to be(true)
      expect(row.cell_for(staging).present).to be(false)
      expect(row.present_count).to eq(1)
      expect(row.absent_count).to eq(1)
    end

    it "conteggia il totale delle assenze sulle righe risultanti" do
      create(:secret_variable, project: project_a, environment: production, organization: org, name: "DATABASE_URL")

      expect(call.total_absences).to eq(1)
    end

    it "un ambiente NON attivo non genera una colonna né una falsa assenza" do
      staging.update!(active: false)
      create(:secret_variable, project: project_a, environment: production, organization: org, name: "DATABASE_URL")

      row = call.rows.find { |r| r.project == project_a }

      expect(row.cells.map { |c| c.environment.code }).to contain_exactly("production")
      expect(row.absent_count).to eq(0)
    end
  end

  describe "filtro per progetto" do
    it "tiene solo le righe del progetto scelto" do
      create(:secret_variable, project: project_a, environment: production, organization: org, name: "DATABASE_URL")
      create(:secret_variable, project: project_b, environment: production, organization: org, name: "DATABASE_URL")

      result = call(project_id: project_a.id)

      expect(result.rows.map(&:project)).to all(eq(project_a))
    end

    it "espone i progetti coinvolti come opzioni di filtro, ordinati per nome" do
      create(:secret_variable, project: project_b, environment: production, organization: org, name: "DATABASE_URL")
      create(:secret_variable, project: project_a, environment: production, organization: org, name: "DATABASE_URL")

      expect(call.project_options).to eq([ [ "Progetto Alfa", project_a.id ], [ "Progetto Beta", project_b.id ] ])
    end
  end

  describe "filtro per ambiente" do
    it "restringe la riga alla sola colonna dell'ambiente scelto" do
      create(:secret_variable, project: project_a, environment: production, organization: org, name: "DATABASE_URL")

      row = call(environment_code: "production").rows.find { |r| r.project == project_a }

      expect(row.cells.map { |c| c.environment.code }).to contain_exactly("production")
    end

    it "esclude i progetti che non hanno quell'ambiente attivo" do
      create(:secret_variable, project: project_a, environment: staging, organization: org, name: "DATABASE_URL")
      create(:secret_variable, project: project_b, environment: production, organization: org, name: "DATABASE_URL")

      result = call(environment_code: "staging")

      expect(result.rows.map(&:project)).to contain_exactly(project_a)
    end

    it "espone gli ambienti coinvolti come opzioni di filtro" do
      create(:secret_variable, project: project_a, environment: production, organization: org, name: "DATABASE_URL")

      expect(call.environment_options).to eq([ [ "Produzione", "production" ], [ "Staging", "staging" ] ])
    end
  end

  describe "ordinamento per occorrenze" do
    it "mette prima la riga con più presenze" do
      create(:secret_variable, project: project_a, environment: production, organization: org, name: "DATABASE_URL")
      create(:secret_variable, project: project_a, environment: staging, organization: org, name: "DATABASE_URL")
      create(:secret_variable, project: project_b, environment: production, organization: org, name: "DATABASE_URL")

      ordered = call(sort: "occurrences").rows

      expect(ordered.first.project).to eq(project_a)
      expect(ordered.first.present_count).to eq(2)
      expect(ordered.last.project).to eq(project_b)
    end

    it "default: ordina per nome e progetto" do
      create(:secret_variable, project: project_b, environment: production, organization: org, name: "DATABASE_URL")
      create(:secret_variable, project: project_a, environment: production, organization: org, name: "DATABASE_URL")

      ordered = call.rows

      expect(ordered.map(&:project)).to eq([ project_a, project_b ])
    end
  end

  describe "paginazione" do
    it "impagina le righe secondo page/per" do
      12.times { |i| create(:secret_variable, project: project_a, environment: production, organization: org, name: "DATABASE_VAR_#{i}") }

      first = call(per: 10, page: 1)
      second = call(per: 10, page: 2)

      expect(first.rows.size).to eq(10)
      expect(second.rows.size).to eq(2)
      expect(first.total_rows).to eq(12)
      expect(first.pagination.total_pages).to eq(2)
    end
  end
end
