require "rails_helper"

RSpec.describe Secrets::Rows::Save do
  let(:project) { create(:project) }
  let(:development) do
    create(:environment, organization: project.organization, code: "development").tap { |e| project.environments << e }
  end
  let(:production) do
    create(:environment, organization: project.organization, code: "production").tap { |e| project.environments << e }
  end

  describe ".call" do
    it "crea una cella per ogni ambiente della riga (N celle, un nome)" do
      cells = [ { environment: development, value: "dev-secret" }, { environment: production, value: "prod-secret" } ]

      expect do
        result = described_class.call(project:, name: "DATABASE_URL", cells:)
        expect(result).to be_ok
        expect(result.value.applied_count).to eq(2)
        expect(result.value.pending_count).to eq(0)
      end.to change { project.secret_variables.count }.by(2)

      expect(project.secret_variables.find_by(environment: development, name: "DATABASE_URL").value).to eq("dev-secret")
      expect(project.secret_variables.find_by(environment: production, name: "DATABASE_URL").value).to eq("prod-secret")
    end

    it "salta le celle con valore blank (non crea, non cancella)" do
      cells = [ { environment: development, value: "only-dev" }, { environment: production, value: "  " } ]

      expect do
        result = described_class.call(project:, name: "API_KEY", cells:)
        expect(result).to be_ok
        expect(result.value.applied_count).to eq(1)
      end.to change { project.secret_variables.count }.by(1)

      expect(project.secret_variables.exists?(environment: production, name: "API_KEY")).to be(false)
    end

    it "fa upsert: aggiorna il valore di una cella esistente senza duplicarla" do
      described_class.call(project:, name: "TOKEN", cells: [ { environment: development, value: "old" } ])

      expect do
        result = described_class.call(project:, name: "TOKEN", cells: [ { environment: development, value: "new" } ])
        expect(result).to be_ok
      end.not_to change { project.secret_variables.count }

      expect(project.secret_variables.find_by(environment: development, name: "TOKEN").value).to eq("new")
    end

    it "è all-or-nothing: una cella invalida fa rollback dell'intera riga" do
      foreign = create(:environment, organization: project.organization, code: "foreign") # NON dichiarato dal progetto
      cells = [ { environment: development, value: "written-first" }, { environment: foreign, value: "invalid-cell" } ]

      expect do
        result = described_class.call(project:, name: "SECRET", cells:)
        expect(result).to be_err
        expect(result.error.code).to eq("R422-SECRET-001")
      end.not_to change { project.secret_variables.count }
    end

    it "rifiuta un nome non conforme (prefisso GITHUB_) senza scrivere nulla" do
      cells = [ { environment: development, value: "x" }, { environment: production, value: "y" } ]

      expect do
        result = described_class.call(project:, name: "GITHUB_TOKEN", cells:)
        expect(result).to be_err
        expect(result.error.code).to eq("R422-SECRET-001")
      end.not_to change { project.secret_variables.count }
    end

    it "rejects a row with no values or description changes" do
      cells = [ { environment: development, value: "" }, { environment: production, value: nil } ]

      expect do
        result = described_class.call(project:, name: "EMPTY", cells:)
        expect(result).to be_err
        expect(result.error.code).to eq("R422-SECRET-001")
      end.not_to change { project.secret_variables.count }
    end
  end

  describe "GitHub sync" do
    let(:repository) { create(:github_repository, :with_env_mapping, sync_secrets: true) }
    let(:synced_project) { repository.project }

    it "enfila il SyncJob UNA sola volta per l'intera riga" do
      cells = [
        { environment: repository.production_environment, value: "p" },
        { environment: repository.staging_environment, value: "s" }
      ]

      expect { described_class.call(project: synced_project, name: "DATABASE_URL", cells:) }
        .to have_enqueued_job(Secrets::Github::SyncJob).exactly(1).times
    end

    it "non enfila nulla se nessuna cella viene scritta" do
      cells = [ { environment: repository.production_environment, value: "" } ]

      expect { described_class.call(project: synced_project, name: "NOOP", cells:) }
        .not_to have_enqueued_job(Secrets::Github::SyncJob)
    end

    it "non enfila nulla se la riga è interamente in attesa di approvazione (nessuna cella applicata)" do
      synced_project.update!(secret_approval_enabled: true)
      synced_project.project_environments.find_by!(environment: repository.production_environment)
                     .update!(approval_required: true)
      cells = [ { environment: repository.production_environment, value: "p" } ]

      expect { described_class.call(project: synced_project, name: "PENDING_ONLY", cells:) }
        .not_to have_enqueued_job(Secrets::Github::SyncJob)
    end
  end

  # CYRA-138, Fase 4 pezzo C1b: ogni cella passa per Secrets::ChangeRequests::Submit invece di Set
  # diretto. Su un ambiente PROTETTO (Secrets::Approval) la cella diventa una ChangeRequest pending
  # invece di essere scritta; sugli altri ambienti della stessa riga il comportamento resta identico a
  # oggi. Una CR pending è un record valido: NON fa fallire/rollback l'intera riga.
  describe "instradamento attraverso Secrets::ChangeRequests::Submit" do
    let(:protected_environment) do
      create(:environment, organization: project.organization, code: "protected_env").tap do |env|
        project.environments << env
        project.update!(secret_approval_enabled: true)
        project.project_environments.find_by!(environment: env).update!(approval_required: true)
      end
    end

    it "riga mista: la cella su ambiente libero è applicata subito, quella su ambiente protetto diventa una change request pending" do
      cells = [ { environment: development, value: "free-value" }, { environment: protected_environment, value: "protected-value" } ]
      result = nil

      expect do
        result = described_class.call(project:, name: "MIXED", cells:)
      end.to change { project.secret_variables.count }.by(1).and change(Secrets::ChangeRequest, :count).by(1)

      expect(result).to be_ok
      expect(result.value.applied_count).to eq(1)
      expect(result.value.pending_count).to eq(1)
      expect(project.secret_variables.find_by(environment: development, name: "MIXED").value).to eq("free-value")
      expect(project.secret_variables.exists?(environment: protected_environment, name: "MIXED")).to be(false)

      change_request = Secrets::ChangeRequest.last
      expect(change_request.environment).to eq(protected_environment)
      expect(change_request.value).to eq("protected-value")
      expect(change_request.status).to eq("pending")
    end

    it "riga interamente su ambiente protetto: nessuna variabile scritta, tutte le celle in attesa" do
      cells = [ { environment: protected_environment, value: "v" } ]

      result = described_class.call(project:, name: "ALL_PENDING", cells:)

      expect(result).to be_ok
      expect(result.value.applied_count).to eq(0)
      expect(result.value.pending_count).to eq(1)
      expect(project.secret_variables.exists?(name: "ALL_PENDING")).to be(false)
    end

    it "una change request pending non innesca il rollback della transazione (non è un errore)" do
      cells = [ { environment: development, value: "free" }, { environment: protected_environment, value: "protected" } ]

      expect do
        described_class.call(project:, name: "ATOMIC", cells:)
      end.to change { project.secret_variables.count }.by(1)
    end

    it "una cella realmente invalida continua a fare rollback dell'intera riga anche in presenza di una cella pending" do
      foreign = create(:environment, organization: project.organization, code: "foreign") # NON dichiarato dal progetto
      cells = [ { environment: protected_environment, value: "would-be-pending" }, { environment: foreign, value: "invalid-cell" } ]

      expect do
        result = described_class.call(project:, name: "ROLLBACK_MIX", cells:)
        expect(result).to be_err
        expect(result.error.code).to eq("R422-SECRET-001")
      end.to not_change(Secrets::ChangeRequest, :count).and not_change { project.secret_variables.count }
    end
  end
end
