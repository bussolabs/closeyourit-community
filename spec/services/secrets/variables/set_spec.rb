require "rails_helper"

RSpec.describe Secrets::Variables::Set do
  let(:project) { create(:project) }
  let(:environment) do
    create(:environment, organization: project.organization).tap { |env| project.environments << env }
  end

  describe ".call" do
    it "crea una nuova variabile cifrando il valore" do
      result = described_class.call(project:, environment:, name: "DATABASE_URL", value: "postgres://x")

      expect(result).to be_ok
      expect(result.value).to be_persisted
      expect(result.value.reload.value).to eq("postgres://x")
    end

    it "normalizza il nome in UPPER_SNAKE" do
      result = described_class.call(project:, environment:, name: "  db_url ", value: "v")
      expect(result.value.name).to eq("DB_URL")
    end

    it "aggiorna (upsert) una variabile esistente senza crearne una seconda" do
      described_class.call(project:, environment:, name: "API_KEY", value: "old")

      expect do
        result = described_class.call(project:, environment:, name: "API_KEY", value: "new")
        expect(result.value.value).to eq("new")
      end.not_to change { project.secret_variables.count }
    end

    it "imposta organization dal progetto" do
      result = described_class.call(project:, environment:, name: "FOO", value: "v")
      expect(result.value.organization_id).to eq(project.organization_id)
    end

    it "imposta created_by dall'actor" do
      actor = create(:account)
      result = described_class.call(project:, environment:, name: "FOO", value: "v", actor:)
      expect(result.value.created_by).to eq(actor)
    end

    it "ritorna Result.err con R422-SECRET-001 su nome invalido" do
      result = described_class.call(project:, environment:, name: "BAD-NAME", value: "v")

      expect(result).to be_err
      expect(result.error.code).to eq("R422-SECRET-001")
    end

    it "accetta una stringa vuota impostata esplicitamente" do
      result = described_class.call(project:, environment:, name: "OPTIONAL_VALUE", value: "")

      expect(result).to be_ok
      expect(result.value.reload.value).to eq("")
    end

    it "rifiuta un valore null" do
      result = described_class.call(project:, environment:, name: "BROKEN_VALUE", value: nil)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-SECRET-001")
      expect(result.error.details).to include(:value)
    end

    it "ritorna Result.err se l'ambiente non è dichiarato dal progetto" do
      undeclared = create(:environment, organization: project.organization)
      result = described_class.call(project:, environment: undeclared, name: "FOO", value: "v")

      expect(result).to be_err
      expect(result.error.code).to eq("R422-SECRET-001")
    end
  end

  # rotated_at (CYRA-138, Fase 4 pezzo A1): la scadenza di rotazione si "ri-arma" da sola riusando il
  # fatto che il PLAINTEXT è cambiato — stesso guard già usato per Versions::Snapshot (value_changed).
  describe "rotated_at" do
    it "inizializza rotated_at alla creazione" do
      travel_to Time.zone.local(2026, 1, 1, 12, 0, 0) do
        result = described_class.call(project:, environment:, name: "FOO", value: "v")
        expect(result.value.rotated_at).to eq(Time.current)
      end
    end

    it "non tocca rotation_interval_days (impostato solo dall'azione dedicata, non da Set)" do
      result = described_class.call(project:, environment:, name: "FOO", value: "v")
      expect(result.value.rotation_interval_days).to be_nil
    end

    it "aggiorna rotated_at quando il plaintext cambia" do
      described_class.call(project:, environment:, name: "API_KEY", value: "old")

      travel_to(1.day.from_now) do
        result = described_class.call(project:, environment:, name: "API_KEY", value: "new")
        expect(result.value.rotated_at).to eq(Time.current)
      end
    end

    it "NON aggiorna rotated_at quando il valore è identico" do
      variable = described_class.call(project:, environment:, name: "API_KEY", value: "same").value
      first_rotated_at = variable.reload.rotated_at

      travel_to(1.day.from_now) do
        result = described_class.call(project:, environment:, name: "API_KEY", value: "same")
        expect(result.value.rotated_at).to eq(first_rotated_at)
      end
    end

    it "NON aggiorna rotated_at quando cambia solo la description (valore identico)" do
      variable = described_class.call(project:, environment:, name: "API_KEY", value: "same", description: "old").value
      first_rotated_at = variable.reload.rotated_at

      travel_to(1.day.from_now) do
        result = described_class.call(project:, environment:, name: "API_KEY", value: "same", description: "new")
        expect(result.value.description).to eq("new")
        expect(result.value.rotated_at).to eq(first_rotated_at)
      end
    end
  end

  # CYRA-777 — dopo un salvataggio parte il giro mirato sulle proposte di «valore in comune». Mirato
  # e non org-wide: guarda un ambiente solo e le impronte toccate, quella nuova e quella di prima.
  describe "giro sulle proposte di valore in comune" do
    include ActiveJob::TestHelper

    it "accoda il giro sull'impronta appena scritta" do
      described_class.call(project:, environment:, name: "API_KEY", value: "valore-lungo-abbastanza")

      expect(Secrets::Consolidation::RefreshJob).to have_been_enqueued.with(
        organization_id: project.organization_id, environment_id: environment.id,
        fingerprints: [ Secrets::Consolidation::Fingerprint.for("valore-lungo-abbastanza") ]
      )
    end

    # Cambiare un valore può far NASCERE una proposta (l'impronta nuova) e insieme farne SPARIRE una
    # (quella vecchia): guardare solo la nuova lascerebbe in lista una proposta su un valore che
    # nessuno tiene più.
    it "porta anche l'impronta di prima quando il valore cambia" do
      described_class.call(project:, environment:, name: "API_KEY", value: "valore-lungo-abbastanza")
      described_class.call(project:, environment:, name: "API_KEY", value: "un-altro-valore-lungo")

      expect(Secrets::Consolidation::RefreshJob).to have_been_enqueued.with(
        organization_id: project.organization_id, environment_id: environment.id,
        fingerprints: [ Secrets::Consolidation::Fingerprint.for("valore-lungo-abbastanza"),
                        Secrets::Consolidation::Fingerprint.for("un-altro-valore-lungo") ]
      )
    end

    it "non accoda niente quando il valore non cambia" do
      described_class.call(project:, environment:, name: "API_KEY", value: "valore-lungo-abbastanza")

      expect do
        described_class.call(project:, environment:, name: "API_KEY", value: "valore-lungo-abbastanza")
      end.not_to have_enqueued_job(Secrets::Consolidation::RefreshJob)
    end

    it "non accoda niente per un valore troppo corto per avere un'impronta" do
      expect do
        described_class.call(project:, environment:, name: "DEBUG", value: "1")
      end.not_to have_enqueued_job(Secrets::Consolidation::RefreshJob)
    end
  end
end
