# frozen_string_literal: true

require "rails_helper"

# Il gancio che ogni mutazione del vault chiama dopo il commit. Tre condizioni vanno tenute ferme, e
# nessuna prova dei singoli service le guarda tutte: niente repository = niente invio, invio spento =
# niente invio, e il job parte per il repository giusto.
RSpec.describe Secrets::Github::Syncable do
  include ActiveJob::TestHelper

  let(:chiamante) do
    Class.new do
      include Secrets::Github::Syncable
    end.new
  end

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }

  it "con l'invio verso GitHub acceso accoda la sincronizzazione di quel repository" do
    repository = create(:github_repository, project:, sync_secrets: true)

    chiamante.enqueue_github_sync(project)

    expect(Secrets::Github::SyncJob)
      .to have_been_enqueued.with(github_repository_id: repository.id)
  end

  it "con l'invio spento non accoda niente: non è un guasto, è la funzione che non deve girare" do
    create(:github_repository, project:, sync_secrets: false)

    chiamante.enqueue_github_sync(project)

    expect(Secrets::Github::SyncJob).not_to have_been_enqueued
  end

  it "un progetto senza repository agganciato non accoda niente" do
    chiamante.enqueue_github_sync(project)

    expect(Secrets::Github::SyncJob).not_to have_been_enqueued
  end

  it "accoda solo per il progetto passato, non per gli altri della stessa organizzazione" do
    mio = create(:github_repository, project:, sync_secrets: true)
    create(:github_repository, project: create(:project, organization:), sync_secrets: true)

    chiamante.enqueue_github_sync(project)

    expect(Secrets::Github::SyncJob).to have_been_enqueued.once
      .with(github_repository_id: mio.id)
  end
end
