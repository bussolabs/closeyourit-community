# frozen_string_literal: true

require "rails_helper"

# Diff cross-ambiente (drift) della matrice secrets di un progetto (CYRA-137, Fase 3 igiene Vault).
# Un "buco" è una variabile LOCALE presente in >= 1 ambiente ATTIVO del progetto e assente in >= 1
# altro ambiente attivo dello stesso progetto. Lavora sui dati GIA' caricati dalla matrice (nessuna
# query nuova): `rows` ha la stessa forma di @rows del controller — array di coppie
# [name, { environment_id => Secrets::Variable }].
RSpec.describe Secrets::Drift do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:production) { create(:environment, organization: org, code: "production").tap { |e| project.environments << e } }
  let(:staging) { create(:environment, organization: org, code: "staging").tap { |e| project.environments << e } }

  # Costruisce una riga della matrice nella stessa forma di @rows: [name, { environment_id => variable }].
  def row_for(name, by_env)
    [ name, by_env ]
  end

  describe "#hole?" do
    it "nessun buco quando la variabile è completa su tutti gli ambienti attivi" do
      var_prod = create(:secret_variable, project:, environment: production, name: "COMPLETE")
      var_staging = create(:secret_variable, project:, environment: staging, name: "COMPLETE")
      rows = [ row_for("COMPLETE", production.id => var_prod, staging.id => var_staging) ]

      drift = described_class.new(rows: rows, environments: [ production, staging ])

      expect(drift.hole?("COMPLETE", production.id)).to be(false)
      expect(drift.hole?("COMPLETE", staging.id)).to be(false)
      expect(drift.holes_count).to eq(0)
      expect(drift.affected_names_count).to eq(0)
      expect(drift.any?).to be(false)
    end

    it "nessun buco quando la variabile è assente su ogni ambiente (riga senza celle valorizzate)" do
      rows = [ row_for("ABSENT", {}) ]

      drift = described_class.new(rows: rows, environments: [ production, staging ])

      expect(drift.hole?("ABSENT", production.id)).to be(false)
      expect(drift.hole?("ABSENT", staging.id)).to be(false)
      expect(drift.holes_count).to eq(0)
      expect(drift.any?).to be(false)
    end

    it "1 buco quando la variabile manca in un solo ambiente su due" do
      var_prod = create(:secret_variable, project:, environment: production, name: "PARTIAL")
      rows = [ row_for("PARTIAL", production.id => var_prod) ]

      drift = described_class.new(rows: rows, environments: [ production, staging ])

      expect(drift.hole?("PARTIAL", production.id)).to be(false)
      expect(drift.hole?("PARTIAL", staging.id)).to be(true)
      expect(drift.holes_count).to eq(1)
      expect(drift.affected_names_count).to eq(1)
      expect(drift.any?).to be(true)
    end

    it "N buchi su più variabili e più ambienti" do
      preprod = create(:environment, organization: org, code: "preprod").tap { |e| project.environments << e }
      environments = [ production, staging, preprod ]

      var_a_prod = create(:secret_variable, project:, environment: production, name: "A")
      var_b_prod = create(:secret_variable, project:, environment: production, name: "B")
      var_b_staging = create(:secret_variable, project:, environment: staging, name: "B")
      rows = [
        row_for("A", production.id => var_a_prod),
        row_for("B", production.id => var_b_prod, staging.id => var_b_staging)
      ]

      drift = described_class.new(rows: rows, environments: environments)

      # A: presente solo in production → buco in staging e preprod.
      expect(drift.hole?("A", production.id)).to be(false)
      expect(drift.hole?("A", staging.id)).to be(true)
      expect(drift.hole?("A", preprod.id)).to be(true)
      # B: presente in production+staging → buco solo in preprod.
      expect(drift.hole?("B", production.id)).to be(false)
      expect(drift.hole?("B", staging.id)).to be(false)
      expect(drift.hole?("B", preprod.id)).to be(true)

      expect(drift.holes_count).to eq(3)
      expect(drift.affected_names_count).to eq(2)
      expect(drift.any?).to be(true)
    end

    it "progetto con un solo ambiente attivo: mai un buco, anche con la variabile presente" do
      var_prod = create(:secret_variable, project:, environment: production, name: "SOLO")
      rows = [ row_for("SOLO", production.id => var_prod) ]

      drift = described_class.new(rows: rows, environments: [ production ])

      expect(drift.hole?("SOLO", production.id)).to be(false)
      expect(drift.holes_count).to eq(0)
      expect(drift.any?).to be(false)
    end

    it "variabile presente ovunque su 3 ambienti: nessun buco" do
      preprod = create(:environment, organization: org, code: "preprod").tap { |e| project.environments << e }
      environments = [ production, staging, preprod ]
      var_prod = create(:secret_variable, project:, environment: production, name: "EVERY")
      var_staging = create(:secret_variable, project:, environment: staging, name: "EVERY")
      var_preprod = create(:secret_variable, project:, environment: preprod, name: "EVERY")
      rows = [ row_for("EVERY", production.id => var_prod, staging.id => var_staging, preprod.id => var_preprod) ]

      drift = described_class.new(rows: rows, environments: environments)

      expect(environments.map { |e| drift.hole?("EVERY", e.id) }).to all(be(false))
      expect(drift.holes_count).to eq(0)
      expect(drift.any?).to be(false)
    end

    it "variabile presente in un solo ambiente su più: buchi in tutti gli altri" do
      preprod = create(:environment, organization: org, code: "preprod").tap { |e| project.environments << e }
      environments = [ production, staging, preprod ]
      var_prod = create(:secret_variable, project:, environment: production, name: "ONLY_PROD")
      rows = [ row_for("ONLY_PROD", production.id => var_prod) ]

      drift = described_class.new(rows: rows, environments: environments)

      expect(drift.hole?("ONLY_PROD", production.id)).to be(false)
      expect(drift.hole?("ONLY_PROD", staging.id)).to be(true)
      expect(drift.hole?("ONLY_PROD", preprod.id)).to be(true)
      expect(drift.holes_count).to eq(2)
      expect(drift.affected_names_count).to eq(1)
    end

    it "espone i buchi uno per uno con #holes (nome → ambienti mancanti)" do
      preprod = create(:environment, organization: org, code: "preprod").tap { |e| project.environments << e }
      environments = [ production, staging, preprod ]
      var_a_prod = create(:secret_variable, project:, environment: production, name: "A")
      var_b_prod = create(:secret_variable, project:, environment: production, name: "B")
      var_b_staging = create(:secret_variable, project:, environment: staging, name: "B")
      rows = [
        row_for("A", production.id => var_a_prod),
        row_for("B", production.id => var_b_prod, staging.id => var_b_staging)
      ]

      drift = described_class.new(rows: rows, environments: environments)

      expect(drift.holes).to eq("A" => [ staging.id, preprod.id ], "B" => [ preprod.id ])
    end

    it "#holes è vuoto quando la matrice è completa" do
      var_prod = create(:secret_variable, project:, environment: production, name: "COMPLETE")
      var_staging = create(:secret_variable, project:, environment: staging, name: "COMPLETE")
      rows = [ row_for("COMPLETE", production.id => var_prod, staging.id => var_staging) ]

      drift = described_class.new(rows: rows, environments: [ production, staging ])

      expect(drift.holes).to be_empty
    end

    it "ignora le celle su un ambiente non attivo (fuori dalla matrice, come farebbe .active nel controller)" do
      # Dichiarato al progetto (altrimenti la variabile non validerebbe) ma disattivato: il controller lo
      # escluderebbe già da @environments via `.active`, quindi non arriva mai nella lista `environments:`.
      archived = create(:environment, organization: org, code: "archived", active: false)
        .tap { |e| project.environments << e }
      var_prod = create(:secret_variable, project:, environment: production, name: "HIDDEN")
      var_archived = create(:secret_variable, project:, environment: archived, name: "HIDDEN")
      rows = [ row_for("HIDDEN", production.id => var_prod, archived.id => var_archived) ]

      drift = described_class.new(rows: rows, environments: [ production, staging ])

      expect(drift.hole?("HIDDEN", production.id)).to be(false)
      expect(drift.hole?("HIDDEN", staging.id)).to be(true)
      expect(drift.holes_count).to eq(1)
    end
  end
end
