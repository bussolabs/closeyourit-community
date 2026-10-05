# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::Notifications::DeletedNotifyJob do
  it "gira sulla coda :notifications" do
    expect(described_class.new.queue_name).to eq("notifications")
  end

  describe "#perform" do
    it "carica progetto e attore dagli id, poi delega al dispatch coi dati snapshottati" do
      project = create(:project)
      actor = create(:account)
      variable_id = SecureRandom.uuid
      allow(Secrets::Notifications::DispatchSecretDeleted).to receive(:call)

      described_class.perform_now(project_id: project.id, variable_id: variable_id, name: "API_KEY",
                                  environment_label: "Production", actor_id: actor.id)

      expect(Secrets::Notifications::DispatchSecretDeleted).to have_received(:call).with(
        project: project, variable_id: variable_id, name: "API_KEY",
        environment_label: "Production", actor: actor
      )
    end

    it "senza actor_id (delete di sistema) delega col dispatch actor: nil" do
      project = create(:project)
      allow(Secrets::Notifications::DispatchSecretDeleted).to receive(:call)

      described_class.perform_now(project_id: project.id, variable_id: SecureRandom.uuid, name: "API_KEY",
                                  environment_label: "Production")

      expect(Secrets::Notifications::DispatchSecretDeleted).to have_received(:call).with(hash_including(actor: nil))
    end

    it "no-op se il progetto non esiste più (cancellato nel frattempo)" do
      allow(Secrets::Notifications::DispatchSecretDeleted).to receive(:call)

      described_class.perform_now(project_id: SecureRandom.uuid, variable_id: SecureRandom.uuid, name: "API_KEY",
                                  environment_label: "Production")

      expect(Secrets::Notifications::DispatchSecretDeleted).not_to have_received(:call)
    end

    it "no-op se l'actor_id non risolve più un account (nullify silenzioso, mai un errore)" do
      project = create(:project)
      allow(Secrets::Notifications::DispatchSecretDeleted).to receive(:call)

      described_class.perform_now(project_id: project.id, variable_id: SecureRandom.uuid, name: "API_KEY",
                                  environment_label: "Production", actor_id: SecureRandom.uuid)

      expect(Secrets::Notifications::DispatchSecretDeleted).to have_received(:call).with(hash_including(actor: nil))
    end
  end
end
