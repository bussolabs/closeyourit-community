# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::Notifications::ChangeRequestNotifyJob do
  it "gira sulla coda :notifications" do
    expect(described_class.new.queue_name).to eq("notifications")
  end

  describe "#perform" do
    it "evento requested → delega a DispatchChangeRequested con la CR ricaricata" do
      change_request = create(:secret_change_request)
      allow(Secrets::Notifications::DispatchChangeRequested).to receive(:call)

      described_class.perform_now(change_request_id: change_request.id, event: "requested")

      expect(Secrets::Notifications::DispatchChangeRequested).to have_received(:call)
        .with(change_request: change_request)
    end

    it "evento approved → delega a DispatchChangeApproved con la CR ricaricata" do
      change_request = create(:secret_change_request, status: :applied)
      allow(Secrets::Notifications::DispatchChangeApproved).to receive(:call)

      described_class.perform_now(change_request_id: change_request.id, event: "approved")

      expect(Secrets::Notifications::DispatchChangeApproved).to have_received(:call)
        .with(change_request: change_request)
    end

    it "evento rejected → delega a DispatchChangeRejected con la CR ricaricata" do
      change_request = create(:secret_change_request, status: :rejected, reason: "no")
      allow(Secrets::Notifications::DispatchChangeRejected).to receive(:call)

      described_class.perform_now(change_request_id: change_request.id, event: "rejected")

      expect(Secrets::Notifications::DispatchChangeRejected).to have_received(:call)
        .with(change_request: change_request)
    end

    it "accetta l'evento come simbolo (normalizzato a stringa)" do
      change_request = create(:secret_change_request)
      allow(Secrets::Notifications::DispatchChangeRequested).to receive(:call)

      described_class.perform_now(change_request_id: change_request.id, event: :requested)

      expect(Secrets::Notifications::DispatchChangeRequested).to have_received(:call)
        .with(change_request: change_request)
    end

    it "no-op se la change request non esiste più (es. rollback della riga protetta in Rows::Save)" do
      allow(Secrets::Notifications::DispatchChangeRequested).to receive(:call)

      described_class.perform_now(change_request_id: SecureRandom.uuid, event: "requested")

      expect(Secrets::Notifications::DispatchChangeRequested).not_to have_received(:call)
    end

    it "no-op difensivo su un evento sconosciuto (nessun dispatch invocato, nessun errore)" do
      change_request = create(:secret_change_request)
      allow(Secrets::Notifications::DispatchChangeRequested).to receive(:call)

      expect { described_class.perform_now(change_request_id: change_request.id, event: "bogus") }
        .not_to raise_error
      expect(Secrets::Notifications::DispatchChangeRequested).not_to have_received(:call)
    end
  end
end
