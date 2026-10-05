# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::ChangeRequests::Cancel do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:environment) { create(:environment, organization:).tap { |env| project.environments << env } }
  let(:requester) { create(:account) }

  def pending_request(**attrs)
    create(:secret_change_request, project:, organization:, environment:, requested_by: requester, **attrs)
  end

  it "il richiedente ritira la propria richiesta: status→cancelled, decided_by/at valorizzati, nessuna applicazione" do
    change_request = pending_request(name: "API_KEY", action: "set", value: "s3cr3t")

    result = described_class.call(change_request:, actor: requester)

    expect(result).to be_ok
    expect(result.value).to eq(change_request)
    expect(change_request.reload).to have_attributes(status: "cancelled", decided_by: requester, decided_at: be_present)
    expect(project.secret_variables.exists?(environment:, name: "API_KEY")).to be(false)
  end

  it "action :remove: ritirare non cancella nulla, il secret esistente resta invariato" do
    Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "v1")
    change_request = pending_request(name: "API_KEY", action: "remove", value: nil)

    result = described_class.call(change_request:, actor: requester)

    expect(result).to be_ok
    expect(change_request.reload.status).to eq("cancelled")
    expect(project.secret_variables.find_by(environment:, name: "API_KEY").value).to eq("v1")
  end

  it "NON accoda alcuna notifica: il richiedente ritira sé stesso, nessuno da avvisare (CYRA-138 pezzo C2c)" do
    change_request = pending_request(name: "API_KEY", action: "set", value: "s3cr3t")

    expect { described_class.call(change_request:, actor: requester) }
      .not_to have_enqueued_job(Secrets::Notifications::ChangeRequestNotifyJob)
  end

  describe "solo il richiedente può ritirare la propria richiesta" do
    it "un altro utente riceve R403, la CR resta pending" do
      change_request = pending_request(name: "API_KEY", action: "set", value: "s3cr3t")
      other = create(:account)

      result = described_class.call(change_request:, actor: other)

      expect(result).to be_err
      expect(result.error.code).to eq("R403-CHANGEREQUEST-002")
      expect(change_request.reload.status).to eq("pending")
    end
  end

  # CYRA-640: il guard umano di Approve/Reject NON si estende qui, ed è voluto. Ritirare non è una
  # decisione che scavalca la doppia approvazione: chiude la propria richiesta senza toccare il secret,
  # e la macchina che l'ha presentata deve poterci rinunciare da sé (altrimenti resta pending per sempre
  # in attesa che un umano la rifiuti).
  describe "un account di servizio ritira la richiesta che ha presentato lui (CYRA-640)" do
    it "la macchina richiedente ritira: status→cancelled, il secret non cambia" do
      machine = create(:account, :service)
      change_request = create(:secret_change_request, project:, organization:, environment:,
                              requested_by: machine, name: "API_KEY", action: "set", value: "s3cr3t")

      result = described_class.call(change_request:, actor: machine)

      expect(result).to be_ok
      expect(change_request.reload.status).to eq("cancelled")
      expect(project.secret_variables.exists?(environment:, name: "API_KEY")).to be(false)
    end
  end

  describe "idempotenza/stale: la richiesta non è più pending" do
    it "una CR già applicata → R409, niente doppio ritiro" do
      change_request = pending_request(name: "API_KEY", action: "set", value: "s3cr3t")
      change_request.update!(status: :applied, decided_by: requester, decided_at: 1.hour.ago)

      result = described_class.call(change_request:, actor: requester)

      expect(result).to be_err
      expect(result.error.code).to eq("R409-CHANGEREQUEST-001")
    end

    it "una CR già ritirata (cancelled) → R409" do
      change_request = pending_request(name: "API_KEY", action: "set", value: "s3cr3t")
      change_request.update!(status: :cancelled, decided_by: requester, decided_at: 1.hour.ago)

      result = described_class.call(change_request:, actor: requester)

      expect(result).to be_err
      expect(result.error.code).to eq("R409-CHANGEREQUEST-001")
    end

    it "una CR già rifiutata → R409" do
      change_request = pending_request(name: "API_KEY", action: "set", value: "s3cr3t")
      change_request.update!(status: :rejected, decided_by: create(:account), decided_at: 1.hour.ago, reason: "no")

      result = described_class.call(change_request:, actor: requester)

      expect(result).to be_err
      expect(result.error.code).to eq("R409-CHANGEREQUEST-001")
    end
  end
end
