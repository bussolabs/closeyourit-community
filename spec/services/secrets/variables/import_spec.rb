require "rails_helper"

RSpec.describe Secrets::Variables::Import do
  let(:project) { create(:project) }
  let(:environment) do
    create(:environment, organization: project.organization).tap { |env| project.environments << env }
  end

  # Protegge la coppia [project, environment] con l'approvazione a due (CYRA-230): stesso schema di
  # Secrets::Approval — master opt-in del progetto + capability approval ON sulla riga join.
  def enable_approval!
    project.update!(secret_approval_enabled: true)
    project.project_environments.find_by!(environment:).update!(approval_required: true)
  end

  describe ".call — ambiente NON protetto (applica subito, come oggi)" do
    it "importa tutte le variabili valide" do
      entries = [ { name: "A", value: "1" }, { name: "B", value: "2" } ]

      expect do
        result = described_class.call(project:, environment:, entries:)
        expect(result).to be_ok
        expect(result.value.applied_count).to eq(2)
        expect(result.value.pending_count).to eq(0)
      end.to change { project.secret_variables.count }.by(2)
    end

    it "è all-or-nothing: una voce invalida fa rollback dell'intero import" do
      entries = [ { name: "GOOD", value: "1" }, { name: "BAD-NAME", value: "2" } ]

      expect do
        result = described_class.call(project:, environment:, entries:)
        expect(result).to be_err
        expect(result.error.code).to eq("R422-SECRET-001")
      end.not_to change { project.secret_variables.count }
    end

    it "importa una stringa vuota esplicita" do
      result = described_class.call(project:, environment:, entries: [ { name: "OPTIONAL_VALUE", value: "" } ])

      expect(result).to be_ok
      expect(project.secret_variables.find_by!(name: "OPTIONAL_VALUE").value).to eq("")
    end

    it "è all-or-nothing se una voce ha valore null" do
      entries = [ { name: "GOOD", value: "1" }, { name: "BROKEN", value: nil } ]

      expect do
        result = described_class.call(project:, environment:, entries:)
        expect(result).to be_err
        expect(result.error.code).to eq("R422-SECRET-001")
      end.not_to change { project.secret_variables.count }
    end

    it "ritorna un Outcome vuoto se non ci sono voci" do
      result = described_class.call(project:, environment:, entries: [])
      expect(result).to be_ok
      expect(result.value.applied_count).to eq(0)
      expect(result.value.pending_count).to eq(0)
    end
  end

  describe ".call — ambiente protetto dall'approvazione a due (CYRA-230)" do
    before { enable_approval! }

    it "NON scrive alcun secret: crea una richiesta pending per ogni voce" do
      entries = [ { name: "A", value: "1" }, { name: "B", value: "2" } ]

      expect do
        result = described_class.call(project:, environment:, entries:)
        expect(result).to be_ok
        expect(result.value.pending_count).to eq(2)
        expect(result.value.applied_count).to eq(0)
      end.to change { Secrets::ChangeRequest.pending.count }.by(2)

      expect(project.secret_variables.count).to eq(0)
    end

    it "non registra l'evento 'imported' né enfila il sync (nulla è stato applicato)" do
      entries = [ { name: "A", value: "1" } ]

      expect { described_class.call(project:, environment:, entries:) }
        .not_to have_enqueued_job(Secrets::Github::SyncJob)
      expect(project.secret_events.where(action: "imported").count).to eq(0)
    end
  end
end
