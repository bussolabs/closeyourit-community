require "rails_helper"

RSpec.describe Secrets::Github::SyncJob do
  it "delega a Secrets::Github::Sync per il repo" do
    repository = create(:github_repository)
    allow(Secrets::Github::Sync).to receive(:call).and_return(Result.ok({ pushed: 0, deleted: 0 }))

    described_class.perform_now(github_repository_id: repository.id)

    expect(Secrets::Github::Sync).to have_received(:call).with(repository:)
  end

  it "no-op se il repo non esiste più" do
    allow(Secrets::Github::Sync).to receive(:call)

    described_class.perform_now(github_repository_id: SecureRandom.uuid)

    expect(Secrets::Github::Sync).not_to have_received(:call)
  end

  describe "notifica di sync fallito (CYRA-138, Fase 4 pezzo B)" do
    it "sync fallito → chiama il dispatch col progetto e il codice errore come motivo sintetico" do
      repository = create(:github_repository)
      error = AppError.new("boom", code: "R502-GITHUB-001")
      allow(Secrets::Github::Sync).to receive(:call).and_return(Result.err(error))
      allow(Secrets::Notifications::DispatchSyncFailed).to receive(:call)

      described_class.perform_now(github_repository_id: repository.id)

      expect(Secrets::Notifications::DispatchSyncFailed).to have_received(:call)
        .with(project: repository.project, reason: "R502-GITHUB-001")
    end

    it "sync fallito → registra codice e dettagli sicuri senza il messaggio libero" do
      repository = create(:github_repository)
      error = AppError.new("messaggio potenzialmente sensibile", code: "R422-GITHUB-009",
                           details: { unset: %w[BROKEN_VALUE] })
      allow(Secrets::Github::Sync).to receive(:call).and_return(Result.err(error))
      allow(Secrets::Notifications::DispatchSyncFailed).to receive(:call)
      allow(Rails.logger).to receive(:warn)

      described_class.perform_now(github_repository_id: repository.id)

      expect(Rails.logger).to have_received(:warn).with(include(
        "Secrets GitHub sync failed", "R422-GITHUB-009", "BROKEN_VALUE", repository.id
      ))
      expect(Rails.logger).not_to have_received(:warn).with(include("messaggio potenzialmente sensibile"))
    end

    it "sync riuscito → NON chiama il dispatch (nessuna notifica)" do
      repository = create(:github_repository)
      allow(Secrets::Github::Sync).to receive(:call).and_return(Result.ok({ pushed: 1, deleted: 0 }))
      allow(Secrets::Notifications::DispatchSyncFailed).to receive(:call)

      described_class.perform_now(github_repository_id: repository.id)

      expect(Secrets::Notifications::DispatchSyncFailed).not_to have_received(:call)
    end
  end
end
