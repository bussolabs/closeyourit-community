# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::ChangeRequests::Submit do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:environment) { create(:environment, organization:).tap { |env| project.environments << env } }
  let(:actor) { create(:account) }

  # Protegge la coppia [project, environment]: master opt-in del progetto ON + capability approval
  # risolta ON sulla riga join (stesso schema di Secrets::Approval, verificato in approval_spec.rb).
  # `environment` è già dichiarato dal progetto (vedi let sopra, `<<` crea la riga join): qui la si
  # AGGIORNA invece di crearne una seconda (violerebbe l'unicità [project_id, environment_id]).
  def protect!(env = environment)
    project.update!(secret_approval_enabled: true)
    project.project_environments.find_by!(environment: env).update!(approval_required: true)
  end

  describe ".call — coppia NON protetta (applica subito, come oggi)" do
    it "action :set su un nome nuovo crea la variabile, nessuna change request" do
      result = described_class.call(project:, environment:, name: "API_KEY", action: :set, value: "v1", actor:)

      expect(result).to be_ok
      expect(result.value).to be_applied
      expect(result.value).not_to be_pending
      expect(result.value.variable).to be_a(Secrets::Variable)
      expect(result.value.variable.reload.value).to eq("v1")
      expect(result.value.change_request).to be_nil
      expect(Secrets::ChangeRequest.count).to eq(0)
    end

    it "action :set fa upsert su una variabile esistente senza duplicarla" do
      described_class.call(project:, environment:, name: "API_KEY", action: :set, value: "old", actor:)

      expect do
        result = described_class.call(project:, environment:, name: "API_KEY", action: :set, value: "new", actor:)
        expect(result.value.variable.value).to eq("new")
      end.not_to change { project.secret_variables.count }
    end

    it "action :set normalizza il nome in UPPER_SNAKE (stesso comportamento di Set)" do
      result = described_class.call(project:, environment:, name: "  db_url ", action: :set, value: "v", actor:)

      expect(result.value.variable.name).to eq("DB_URL")
    end

    it "action :set con nome invalido ritorna lo stesso Result.err di Set (R422-SECRET-001), nessuna variabile" do
      result = described_class.call(project:, environment:, name: "BAD-NAME", action: :set, value: "v", actor:)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-SECRET-001")
      expect(Secrets::Variable.count).to eq(0)
    end

    it "action :remove rimuove la variabile esistente, nessuna change request" do
      Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "v1")

      result = described_class.call(project:, environment:, name: "API_KEY", action: :remove, actor:)

      expect(result).to be_ok
      expect(result.value).to be_applied
      expect(Secrets::Variable.exists?(project:, environment:, name: "API_KEY")).to be(false)
      expect(Secrets::ChangeRequest.count).to eq(0)
    end

    it "action :remove su una variabile già assente è un no-op idempotente (nessun errore)" do
      result = described_class.call(project:, environment:, name: "GHOST", action: :remove, actor:)

      expect(result).to be_ok
      expect(result.value).to be_applied
      expect(result.value.variable).to be_nil
    end

    it "master OFF anche con approval_required ON sull'ambiente dichiarato → applica comunque (nessuna CR)" do
      project.project_environments.find_by!(environment:).update!(approval_required: true) # capability ON
      project.update!(secret_approval_enabled: false) # master OFF (default)

      result = described_class.call(project:, environment:, name: "API_KEY", action: :set, value: "v", actor:)

      expect(result.value).to be_applied
      expect(Secrets::ChangeRequest.count).to eq(0)
    end

    it "nessuna change request creata → nessuna notifica accodata (CYRA-138 pezzo C2c)" do
      expect { described_class.call(project:, environment:, name: "API_KEY", action: :set, value: "v", actor:) }
        .not_to have_enqueued_job(Secrets::Notifications::ChangeRequestNotifyJob)
    end

    it "audit: false propaga a Set e sopprime l'evento 'set' (usato dall'import bulk, CYRA-230)" do
      expect do
        described_class.call(project:, environment:, name: "API_KEY", action: :set, value: "v", actor:, audit: false)
      end.not_to change { project.secret_events.where(action: "set").count }
    end
  end

  describe ".call — coppia PROTETTA (secret_approval_enabled + approval_required)" do
    before { protect! }

    it "action :set NON applica: crea una ChangeRequest pending con i dati corretti" do
      result = nil

      expect do
        result = described_class.call(project:, environment:, name: "API_KEY", action: :set, value: "s3cr3t", actor:)
      end.to change(Secrets::ChangeRequest, :count).by(1)

      expect(result).to be_ok
      expect(result.value).to be_pending
      expect(result.value).not_to be_applied
      expect(result.value.variable).to be_nil

      change_request = result.value.change_request
      expect(change_request.project).to eq(project)
      expect(change_request.environment).to eq(environment)
      expect(change_request.organization).to eq(organization)
      expect(change_request.name).to eq("API_KEY")
      expect(change_request).to be_set
      expect(change_request.value).to eq("s3cr3t")
      expect(change_request.requested_by).to eq(actor)
      expect(change_request.status).to eq("pending")
      expect(change_request.source_version).to be_nil
    end

    it "action :set: la variabile reale NON viene creata" do
      described_class.call(project:, environment:, name: "API_KEY", action: :set, value: "s3cr3t", actor:)

      expect(Secrets::Variable.exists?(project:, environment:, name: "API_KEY")).to be(false)
    end

    it "action :set su una variabile ESISTENTE: il valore reale resta invariato, la CR porta il nuovo valore proposto" do
      Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "old")

      result = described_class.call(project:, environment:, name: "API_KEY", action: :set, value: "new", actor:)

      expect(result.value).to be_pending
      expect(project.secret_variables.find_by(environment:, name: "API_KEY").value).to eq("old")
      expect(result.value.change_request.value).to eq("new")
    end

    it "action :set: il valore proposto è cifrato at-rest (mai in chiaro nella colonna grezza)" do
      result = described_class.call(project:, environment:, name: "API_KEY", action: :set, value: "s3cr3t-plain", actor:)

      raw = ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array(
          [ "SELECT value FROM secrets_change_requests WHERE id = ?", result.value.change_request.id ]
        )
      )
      expect(raw).not_to include("s3cr3t-plain")
    end

    it "action :remove NON applica: crea una ChangeRequest pending con value nil, la variabile resta presente" do
      variable = Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "v1").value
      result = nil

      expect do
        result = described_class.call(project:, environment:, name: "API_KEY", action: :remove, actor:)
      end.to change(Secrets::ChangeRequest, :count).by(1)

      expect(result).to be_ok
      expect(result.value).to be_pending

      change_request = result.value.change_request
      expect(change_request).to be_remove
      expect(change_request.value).to be_nil
      expect(change_request.name).to eq("API_KEY")

      expect(Secrets::Variable.exists?(variable.id)).to be(true)
      expect(variable.reload.value).to eq("v1")
    end

    it "propaga source_version nella change request (flusso di rollback)" do
      variable = Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "old").value
      version = variable.versions.ordered.last

      result = described_class.call(project:, environment:, name: "API_KEY", action: :set, value: "old",
                                     source_version: version, actor:)

      expect(result.value.change_request.source_version).to eq(version)
    end

    it "nome invalido → Result.err, nessuna change request creata" do
      result = nil

      expect do
        result = described_class.call(project:, environment:, name: "BAD-NAME", action: :set, value: "v", actor:)
      end.not_to change(Secrets::ChangeRequest, :count)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-SECRET-004")
    end

    it "NON invoca Secrets::Variables::Set né Secrets::Variables::Delete (nessuna applicazione)" do
      expect(Secrets::Variables::Set).not_to receive(:call)
      expect(Secrets::Variables::Delete).not_to receive(:call)

      described_class.call(project:, environment:, name: "API_KEY", action: :set, value: "s3cr3t", actor:)
    end

    it "accoda la notifica di richiesta (evento requested) con l'id della change request creata (CYRA-138 pezzo C2c)" do
      result = described_class.call(project:, environment:, name: "API_KEY", action: :set, value: "s3cr3t", actor:)

      expect(Secrets::Notifications::ChangeRequestNotifyJob)
        .to have_been_enqueued.with(change_request_id: result.value.change_request.id, event: "requested")
    end

    it "nome invalido: nessuna change request creata → nessuna notifica accodata" do
      expect do
        described_class.call(project:, environment:, name: "BAD-NAME", action: :set, value: "v", actor:)
      end.not_to have_enqueued_job(Secrets::Notifications::ChangeRequestNotifyJob)
    end
  end
end
