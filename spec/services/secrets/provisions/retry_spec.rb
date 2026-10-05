# frozen_string_literal: true

require "rails_helper"

# Riprovare una distribuzione fallita. Il punto delicato è che riprovare NON deve diventare un modo
# per aggirare la configurazione: se il progetto destinatario non ha l'invio verso GitHub acceso e
# mappato, il tentativo si ferma qui con un messaggio che dice cosa manca, invece di rimettere in coda
# un lavoro che fallirebbe di nuovo.
RSpec.describe Secrets::Provisions::Retry do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:actor) { create(:account) }
  let(:destination_project) { create(:project, organization:) }
  let(:production) do
    create(:environment, organization:, code: "production").tap do |env|
      destination_project.environments << env
    end
  end
  let!(:repository) do
    create(:github_repository, project: destination_project, sync_secrets: true,
                               production_environment: production)
  end
  let(:provision) do
    create(:secret_provision, organization:, destination_project:, destination_environment: production,
                              source_project: destination_project, source_environment: production,
                              status: :failed, error_code: "R502-GITHUB-001", error_message: "boom")
  end

  it "denies an all-environment retry when the actor only has a project allow-list" do
    create(:membership, account: actor, organization:, role: :owner)
    create(:account_secret_access, account: actor, project: destination_project, organization:,
                                  environment_codes: [ production.code ])

    expect do
      result = described_class.call(actor:, provision:)
      expect(result.error.code).to eq("R403-PROVISION-001")
    end.not_to have_enqueued_job(Secrets::Provisions::SyncJob)
    expect(provision.reload).to be_failed
  end

  it "rejects a missing actor before changing the provision" do
    result = described_class.call(actor: nil, provision:)

    expect(result.error.code).to eq("R403-PROVISION-001")
    expect(provision.reload).to be_failed
  end

  it "rimette la distribuzione in coda e cancella l'esito fallito di prima" do
    result = described_class.call(actor:, provision:)

    expect(result).to be_ok
    expect(provision.reload).to be_pending_sync
    expect(provision.error_code).to be_nil
    expect(provision.error_message).to be_nil
    expect(Secrets::Provisions::SyncJob).to have_been_enqueued.with(provision_id: provision.id)
  end

  it "una distribuzione già arrivata non si rifà: non c'è niente da riprovare" do
    provision.update!(status: :ready, error_code: nil, error_message: nil)

    result = described_class.call(actor:, provision:)

    expect(result).to be_ok
    expect(provision.reload).to be_ready
    expect(Secrets::Provisions::SyncJob).not_to have_been_enqueued
  end

  it "col progetto destinatario senza invio verso GitHub dice cosa manca invece di riprovare" do
    repository.update!(sync_secrets: false)

    result = described_class.call(actor:, provision:)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-PROVISION-004")
    expect(result.error.message).to eq(I18n.t("provisions.errors.github_required"))
    expect(provision.reload).to be_failed
    expect(Secrets::Provisions::SyncJob).not_to have_been_enqueued
  end

  it "senza repository agganciato non si riprova" do
    provision
    repository.destroy!

    # Ricaricata dal database come la leggerebbe la richiesta vera: l'oggetto costruito dalla prova si
    # porta dietro l'aggancio in memoria e nasconderebbe proprio il caso che qui si vuole guardare.
    result = described_class.call(actor:, provision: Secrets::Provision.find(provision.id))

    expect(result).to be_err
    expect(result.error.code).to eq("R422-PROVISION-004")
  end

  it "una distribuzione che non chiedeva GitHub non si riprova da qui" do
    senza_github = create(:secret_provision, organization:, destination_project:,
                                             destination_environment: production,
                                             source_project: destination_project,
                                             source_environment: production,
                                             status: :failed, sync_github: false)

    expect(described_class.call(actor:, provision: senza_github).error.code).to eq("R422-PROVISION-004")
  end

  # L'ambiente di destinazione deve essere uno dei due mappati sul repository: mandare i secret di
  # produzione su un ambiente non mappato vorrebbe dire scriverli dove nessuno se li aspetta.
  it "un ambiente fuori dalla mappa del repository non si riprova" do
    fuori_mappa = create(:environment, organization:, code: "preview")
    destination_project.environments << fuori_mappa
    provision_fuori = create(:secret_provision, organization:, destination_project:,
                                                destination_environment: fuori_mappa,
                                                source_project: destination_project,
                                                source_environment: fuori_mappa, status: :failed)

    expect(described_class.call(actor:, provision: provision_fuori).error.code).to eq("R422-PROVISION-004")
  end

  it "l'ambiente di staging mappato va bene quanto quello di produzione" do
    staging = create(:environment, organization:, code: "staging")
    destination_project.environments << staging
    repository.update!(staging_environment: staging)
    su_staging = create(:secret_provision, organization:, destination_project:,
                                           destination_environment: staging,
                                           source_project: destination_project,
                                           source_environment: staging, status: :failed)

    expect(described_class.call(actor:, provision: su_staging)).to be_ok
    expect(su_staging.reload).to be_pending_sync
  end

  it "se la riga non è più salvabile risponde con un errore di dominio, non con un'eccezione" do
    allow(provision).to receive(:update!).and_raise(
      ActiveRecord::RecordInvalid.new(Secrets::Provision.new)
    )

    result = described_class.call(actor:, provision:)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-PROVISION-002")
    expect(Secrets::Provisions::SyncJob).not_to have_been_enqueued
  end
end
