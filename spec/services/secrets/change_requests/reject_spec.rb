# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::ChangeRequests::Reject do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:environment) { create(:environment, organization:).tap { |env| project.environments << env } }
  let(:requester) { create(:account) }
  let(:approver) { create(:account) }

  def pending_request(**attrs)
    create(:secret_change_request, project:, organization:, environment:, requested_by: requester, **attrs)
  end

  it "rifiuta con motivo: status→rejected, reason salvata, decided_by/at valorizzati, il secret NON cambia" do
    change_request = pending_request(name: "API_KEY", action: "set", value: "s3cr3t")

    result = described_class.call(change_request:, actor: approver, reason: "Valore non sicuro")

    expect(result).to be_ok
    expect(result.value).to eq(change_request)
    expect(change_request.reload).to have_attributes(
      status: "rejected", reason: "Valore non sicuro", decided_by: approver, decided_at: be_present
    )
    expect(project.secret_variables.exists?(environment:, name: "API_KEY")).to be(false)
  end

  it "action :remove: rifiutare non cancella nulla, il secret esistente resta invariato" do
    Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "v1")
    change_request = pending_request(name: "API_KEY", action: "remove", value: nil)

    result = described_class.call(change_request:, actor: approver, reason: "non serve più rimuoverlo")

    expect(result).to be_ok
    expect(change_request.reload.status).to eq("rejected")
    expect(project.secret_variables.find_by(environment:, name: "API_KEY").value).to eq("v1")
  end

  it "accoda la notifica di rifiuto (evento rejected) dopo la decisione (CYRA-138 pezzo C2c)" do
    change_request = pending_request(name: "API_KEY", action: "set", value: "s3cr3t")

    expect { described_class.call(change_request:, actor: approver, reason: "Valore non sicuro") }
      .to have_enqueued_job(Secrets::Notifications::ChangeRequestNotifyJob)
      .with(change_request_id: change_request.id, event: "rejected")
  end

  describe "motivo obbligatorio" do
    it "motivo assente → R422, la CR resta pending" do
      change_request = pending_request(name: "API_KEY", action: "set", value: "s3cr3t")

      result = described_class.call(change_request:, actor: approver, reason: "")

      expect(result).to be_err
      expect(result.error.code).to eq("R422-CHANGEREQUEST-001")
      expect(change_request.reload.status).to eq("pending")
    end

    it "motivo nil → R422" do
      change_request = pending_request(name: "API_KEY", action: "set", value: "s3cr3t")

      result = described_class.call(change_request:, actor: approver, reason: nil)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-CHANGEREQUEST-001")
    end

    it "motivo di soli spazi (dopo strip è blank) → R422" do
      change_request = pending_request(name: "API_KEY", action: "set", value: "s3cr3t")

      result = described_class.call(change_request:, actor: approver, reason: "   ")

      expect(result).to be_err
      expect(result.error.code).to eq("R422-CHANGEREQUEST-001")
    end

    it "normalizza il motivo con strip prima di salvarlo" do
      change_request = pending_request(name: "API_KEY", action: "set", value: "s3cr3t")

      described_class.call(change_request:, actor: approver, reason: "  motivo con spazi  ")

      expect(change_request.reload.reason).to eq("motivo con spazi")
    end

    it "motivo assente: nessuna notifica di rifiuto accodata (CYRA-138 pezzo C2c)" do
      change_request = pending_request(name: "API_KEY", action: "set", value: "s3cr3t")

      expect { described_class.call(change_request:, actor: approver, reason: "") }
        .not_to have_enqueued_job(Secrets::Notifications::ChangeRequestNotifyJob)
    end
  end

  describe "vincolo 4-eyes: chi decide non può essere chi ha chiesto" do
    it "il richiedente che rifiuta la propria richiesta riceve R403, la CR resta pending" do
      change_request = pending_request(name: "API_KEY", action: "set", value: "s3cr3t")

      result = described_class.call(change_request:, actor: requester, reason: "motivo valido")

      expect(result).to be_err
      expect(result.error.code).to eq("R403-CHANGEREQUEST-001")
      expect(change_request.reload.status).to eq("pending")
    end

    it "self-decision: nessuna notifica di rifiuto accodata (CYRA-138 pezzo C2c)" do
      change_request = pending_request(name: "API_KEY", action: "set", value: "s3cr3t")

      expect { described_class.call(change_request:, actor: requester, reason: "motivo valido") }
        .not_to have_enqueued_job(Secrets::Notifications::ChangeRequestNotifyJob)
    end
  end

  # CYRA-640: gemello del guard in Approve. Anche il rifiuto è una DECISIONE: se la può prendere una
  # macchina, la richiesta si chiude (rejected, congelata, non più ridecidibile) senza che nessuna
  # persona l'abbia mai vista.
  describe "vincolo umano: solo una persona può decidere (CYRA-640)" do
    let(:machine) { create(:account, :service) }

    it "un account di servizio diverso dal richiedente → R403, la CR resta pending" do
      change_request = pending_request(name: "API_KEY", action: "set", value: "s3cr3t")

      result = described_class.call(change_request:, actor: machine, reason: "motivo valido")

      expect(result).to be_err
      expect(result.error.code).to eq("R403-CHANGEREQUEST-003")
      expect(result.error.status).to eq(:forbidden)
      expect(change_request.reload).to have_attributes(status: "pending", reason: nil, decided_by: nil,
                                                       decided_at: nil)
    end

    it "il guard umano precede il controllo del motivo: senza motivo l'esito resta R403, non R422" do
      change_request = pending_request(name: "API_KEY", action: "set", value: "s3cr3t")

      result = described_class.call(change_request:, actor: machine, reason: "")

      expect(result.error.code).to eq("R403-CHANGEREQUEST-003")
    end

    it "un account di servizio non accoda nessuna notifica di rifiuto" do
      change_request = pending_request(name: "API_KEY", action: "set", value: "s3cr3t")

      expect { described_class.call(change_request:, actor: machine, reason: "motivo valido") }
        .not_to have_enqueued_job(Secrets::Notifications::ChangeRequestNotifyJob)
    end

    it "una richiesta PRESENTATA da un account di servizio resta rifiutabile da una persona" do
      change_request = create(:secret_change_request, project:, organization:, environment:,
                              requested_by: machine, name: "API_KEY", action: "set", value: "s3cr3t")

      result = described_class.call(change_request:, actor: approver, reason: "Valore non sicuro")

      expect(result).to be_ok
      expect(change_request.reload.status).to eq("rejected")
    end
  end

  describe "idempotenza/stale: la richiesta non è più pending" do
    it "una CR già applicata → R409" do
      change_request = pending_request(name: "API_KEY", action: "set", value: "s3cr3t")
      change_request.update!(status: :applied, decided_by: approver, decided_at: Time.current)

      result = described_class.call(change_request:, actor: approver, reason: "motivo")

      expect(result).to be_err
      expect(result.error.code).to eq("R409-CHANGEREQUEST-001")
    end

    it "una CR già ritirata (cancelled) → R409" do
      change_request = pending_request(name: "API_KEY", action: "set", value: "s3cr3t")
      change_request.update!(status: :cancelled, decided_by: requester, decided_at: Time.current)

      result = described_class.call(change_request:, actor: approver, reason: "motivo")

      expect(result).to be_err
      expect(result.error.code).to eq("R409-CHANGEREQUEST-001")
    end
  end
end
