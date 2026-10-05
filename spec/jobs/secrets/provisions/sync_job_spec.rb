# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::Provisions::SyncJob, type: :job do
  let(:project) { create(:project) }
  let(:repository) do
    create(:github_repository, project:, sync_secrets: true,
                               staging_environment: provision.destination_environment)
  end
  let(:provision) do
    create(:secret_provision, destination_project: project, source_project: project,
                              organization: project.organization, sync_github: true)
  end

  before { repository }

  it "marca ready una sincronizzazione riuscita" do
    allow(Secrets::Github::Sync).to receive(:call).with(repository:).and_return(Result.ok(pushed: 1))

    described_class.perform_now(provision_id: provision.id)

    expect(provision.reload).to be_ready
    expect(provision.synced_at).to be_present
    expect(provision.error_code).to be_nil
  end

  it "marca failed senza salvare dettagli sensibili quando il sync fallisce" do
    allow(Secrets::Github::Sync).to receive(:call).with(repository:).and_return(
      Result.err(AppError.new("errore GitHub", code: "R422-GITHUB-006"))
    )

    described_class.perform_now(provision_id: provision.id)

    expect(provision.reload).to be_failed
    expect(provision.error_code).to eq("R422-GITHUB-006")
    expect(provision.error_message).to eq(I18n.t("provisions.errors.sync_failed"))
  end

  it "ignora una provision già ready" do
    provision.update!(status: :ready, synced_at: Time.current)
    expect(Secrets::Github::Sync).not_to receive(:call)

    described_class.perform_now(provision_id: provision.id)
  end

  it "fallisce se il mapping viene rimosso prima del job" do
    repository.update!(staging_environment: nil)

    described_class.perform_now(provision_id: provision.id)

    expect(provision.reload).to be_failed
    expect(provision.error_code).to eq("R422-PROVISION-004")
  end
end
