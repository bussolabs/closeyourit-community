# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::ChangeRequests::Approve do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:environment) { create(:environment, organization:).tap { |env| project.environments << env } }
  let(:requester) { create(:account) }
  let(:approver) { create(:account) }

  def pending_request(**attrs)
    create(:secret_change_request, project:, organization:, environment:, requested_by: requester, **attrs)
  end

  describe ".call — action :set" do
    it "applica: crea la variabile col valore della richiesta e marca la CR come applicata" do
      change_request = pending_request(name: "API_KEY", action: "set", value: "s3cr3t")

      result = described_class.call(change_request:, actor: approver)

      expect(result).to be_ok
      expect(result.value).to eq(change_request)
      expect(change_request.reload).to have_attributes(status: "applied", decided_by: approver, decided_at: be_present)

      variable = project.secret_variables.find_by(environment:, name: "API_KEY")
      expect(variable).to be_present
      expect(variable.value).to eq("s3cr3t")
    end

    it "aggiorna (upsert) una variabile ESISTENTE col nuovo valore proposto dalla richiesta" do
      Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "old")
      change_request = pending_request(name: "API_KEY", action: "set", value: "new")

      described_class.call(change_request:, actor: approver)

      expect(project.secret_variables.find_by(environment:, name: "API_KEY").value).to eq("new")
      expect(project.secret_variables.where(environment:, name: "API_KEY").count).to eq(1)
    end

    it "l'evento audit dell'applicazione registra come actor il RICHIEDENTE, non l'approvatore" do
      change_request = pending_request(name: "API_KEY", action: "set", value: "s3cr3t")

      described_class.call(change_request:, actor: approver)

      event = Secrets::Event.where(project:, action: "set", name: "API_KEY").last
      expect(event).to be_present
      expect(event.actor).to eq(requester)
    end

    it "accoda la notifica di approvazione (evento approved) dopo l'applicazione (CYRA-138 pezzo C2c)" do
      change_request = pending_request(name: "API_KEY", action: "set", value: "s3cr3t")

      expect { described_class.call(change_request:, actor: approver) }
        .to have_enqueued_job(Secrets::Notifications::ChangeRequestNotifyJob)
        .with(change_request_id: change_request.id, event: "approved")
    end
  end

  describe ".call — action :remove" do
    it "applica: cancella la variabile esistente e marca la CR come applicata" do
      Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "v1")
      change_request = pending_request(name: "API_KEY", action: "remove", value: nil)

      result = described_class.call(change_request:, actor: approver)

      expect(result).to be_ok
      expect(change_request.reload.status).to eq("applied")
      expect(project.secret_variables.exists?(environment:, name: "API_KEY")).to be(false)
    end

    it "su una variabile già assente è idempotente: nessun errore, la CR è comunque marcata applicata" do
      change_request = pending_request(name: "GHOST", action: "remove", value: nil)

      result = described_class.call(change_request:, actor: approver)

      expect(result).to be_ok
      expect(change_request.reload.status).to eq("applied")
    end

    it "l'evento audit di cancellazione registra come actor il RICHIEDENTE" do
      Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "v1")
      change_request = pending_request(name: "API_KEY", action: "remove", value: nil)

      described_class.call(change_request:, actor: approver)

      event = Secrets::Event.where(project:, action: "deleted", name: "API_KEY").last
      expect(event).to be_present
      expect(event.actor).to eq(requester)
    end
  end

  describe "vincolo 4-eyes: chi decide non può essere chi ha chiesto" do
    it "il richiedente che approva la propria richiesta riceve R403, la CR resta pending, il secret NON cambia" do
      change_request = pending_request(name: "API_KEY", action: "set", value: "s3cr3t")

      result = described_class.call(change_request:, actor: requester)

      expect(result).to be_err
      expect(result.error.code).to eq("R403-CHANGEREQUEST-001")
      expect(change_request.reload.status).to eq("pending")
      expect(project.secret_variables.exists?(environment:, name: "API_KEY")).to be(false)
    end

    it "self-decision: nessuna notifica di approvazione accodata (CYRA-138 pezzo C2c)" do
      change_request = pending_request(name: "API_KEY", action: "set", value: "s3cr3t")

      expect { described_class.call(change_request:, actor: requester) }
        .not_to have_enqueued_job(Secrets::Notifications::ChangeRequestNotifyJob)
    end
  end

  # CYRA-640: la doppia approvazione esiste per mettere DUE PERSONE fra una modifica ai secret di un
  # ambiente protetto e la sua applicazione. Il vincolo 4-eyes da solo NON basta: un account di servizio
  # con secrets.manage è un attore diverso dal richiedente, quindi lo superava e chiudeva il secondo
  # passaggio senza nessun umano nel mezzo.
  describe "vincolo umano: solo una persona può decidere (CYRA-640)" do
    let(:machine) { create(:account, :service) }

    it "un account di servizio diverso dal richiedente → R403, la CR resta pending, il secret NON cambia" do
      change_request = pending_request(name: "API_KEY", action: "set", value: "s3cr3t")

      result = described_class.call(change_request:, actor: machine)

      expect(result).to be_err
      expect(result.error.code).to eq("R403-CHANGEREQUEST-003")
      expect(result.error.status).to eq(:forbidden)
      expect(change_request.reload).to have_attributes(status: "pending", decided_by: nil, decided_at: nil)
      expect(project.secret_variables.exists?(environment:, name: "API_KEY")).to be(false)
    end

    it "un account di servizio non lascia traccia in cronologia: nessun evento di audit sul secret" do
      change_request = pending_request(name: "API_KEY", action: "set", value: "s3cr3t")

      expect { described_class.call(change_request:, actor: machine) }
        .not_to change { Secrets::Event.where(project:, name: "API_KEY").count }
    end

    it "un account di servizio non accoda nessuna notifica di approvazione" do
      change_request = pending_request(name: "API_KEY", action: "set", value: "s3cr3t")

      expect { described_class.call(change_request:, actor: machine) }
        .not_to have_enqueued_job(Secrets::Notifications::ChangeRequestNotifyJob)
    end

    it "il guard umano precede lock e stato: su una CR già decisa la macchina riceve comunque R403" do
      change_request = pending_request(name: "API_KEY", action: "set", value: "s3cr3t")
      change_request.update!(status: :applied, decided_by: approver, decided_at: Time.current)

      result = described_class.call(change_request:, actor: machine)

      expect(result.error.code).to eq("R403-CHANGEREQUEST-003")
    end

    it "una richiesta PRESENTATA da un account di servizio resta approvabile da una persona" do
      change_request = create(:secret_change_request, project:, organization:, environment:,
                              requested_by: machine, name: "API_KEY", action: "set", value: "s3cr3t")

      result = described_class.call(change_request:, actor: approver)

      expect(result).to be_ok
      expect(change_request.reload.status).to eq("applied")
    end
  end

  describe "idempotenza/stale: la richiesta non è più pending" do
    it "una CR già applicata → R409, nessuna nuova applicazione" do
      change_request = pending_request(name: "API_KEY", action: "set", value: "s3cr3t")
      change_request.update!(status: :applied, decided_by: approver, decided_at: Time.current)

      result = described_class.call(change_request:, actor: create(:account))

      expect(result).to be_err
      expect(result.error.code).to eq("R409-CHANGEREQUEST-001")
    end

    it "una CR già rifiutata → R409" do
      change_request = pending_request(name: "API_KEY", action: "set", value: "s3cr3t")
      change_request.update!(status: :rejected, decided_by: approver, decided_at: Time.current, reason: "no")

      result = described_class.call(change_request:, actor: approver)

      expect(result).to be_err
      expect(result.error.code).to eq("R409-CHANGEREQUEST-001")
    end

    it "una CR già ritirata (cancelled) → R409" do
      change_request = pending_request(name: "API_KEY", action: "set", value: "s3cr3t")
      change_request.update!(status: :cancelled, decided_by: requester, decided_at: Time.current)

      result = described_class.call(change_request:, actor: approver)

      expect(result).to be_err
      expect(result.error.code).to eq("R409-CHANGEREQUEST-001")
    end
  end

  describe "applicazione fallita (l'errore propaga, la CR NON viene marcata applicata)" do
    it "capability secrets OFF sull'ambiente in creazione → Result.err propagato, transazione atomica" do
      change_request = pending_request(name: "NEW_VAR", action: "set", value: "s3cr3t")
      project.project_environments.find_by!(environment:).update!(secrets_enabled: false)

      result = described_class.call(change_request:, actor: approver)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-SECRET-001")
      expect(change_request.reload.status).to eq("pending")
      expect(project.secret_variables.exists?(environment:, name: "NEW_VAR")).to be(false)
    end

    it "applicazione fallita: nessuna notifica di approvazione accodata (CYRA-138 pezzo C2c)" do
      change_request = pending_request(name: "NEW_VAR", action: "set", value: "s3cr3t")
      project.project_environments.find_by!(environment:).update!(secrets_enabled: false)

      expect { described_class.call(change_request:, actor: approver) }
        .not_to have_enqueued_job(Secrets::Notifications::ChangeRequestNotifyJob)
    end
  end
end
