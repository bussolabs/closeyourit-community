# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::Tokens::Provision, type: :service do
  include ActiveJob::TestHelper

  let(:actor) { create(:account) }
  let(:organization) { create(:organization) }
  let(:source_project) { create(:project, organization:) }
  let(:destination_project) { create(:project, organization:) }
  let(:source_environment) do
    create(:environment, organization:, code: "staging").tap { |environment| source_project.environments << environment }
  end
  let(:destination_environment) do
    create(:environment, organization:, code: "development").tap do |environment|
      destination_project.environments << environment
    end
  end
  let(:attributes) do
    {
      source_project:, source_environment:, destination_project:, destination_environment:,
      name: "CloseYourIt ingest", secret_name: "CLOSEYOURIT_TOKEN", created_by: actor,
      scopes: [ "ingest" ], idempotency_key: "req-123", sync_github: false
    }
  end

  describe "environment authorization" do
    before { create(:membership, account: actor, organization:, role: :owner) }

    it "rejects a missing actor before issuing a credential" do
      expect(Projects::Tokens::Issue).not_to receive(:call)

      result = described_class.call(**attributes.merge(created_by: nil))

      expect(result.error.code).to eq("R403-PROVISION-001")
    end

    [ :source_project, :destination_project ].each do |target|
      it "rejects a restricted #{target} before issuing or saving credentials" do
        create(:account_secret_access, account: actor, project: public_send(target), organization:,
                                      environment_codes: [ "production" ])
        expect(Projects::Tokens::Issue).not_to receive(:call)
        expect(Secrets::Variables::Set).not_to receive(:call)

        result = described_class.call(**attributes)

        expect(result).to be_err
        expect(result.error.code).to eq("R403-PROVISION-001")
        expect(organization.secret_provisions).to be_empty
      end
    end

    it "checks current access before replaying an idempotent request" do
      expect(described_class.call(**attributes)).to be_ok
      create(:account_secret_access, account: actor, project: destination_project, organization:,
                                    environment_codes: [ "production" ])

      result = described_class.call(**attributes)

      expect(result).to be_err
      expect(result.error.code).to eq("R403-PROVISION-001")
    end

    it "allows the exact source and destination environments" do
      create(:account_secret_access, account: actor, project: source_project, organization:,
                                    environment_codes: [ source_environment.code ])
      create(:account_secret_access, account: actor, project: destination_project, organization:,
                                    environment_codes: [ destination_environment.code ])

      expect(described_class.call(**attributes)).to be_ok
    end

    it "refuses an all-environment export even when the destination environment is allowed" do
      create(:account_secret_access, account: actor, project: destination_project, organization:,
                                    environment_codes: [ destination_environment.code ])
      expect(Projects::Tokens::Issue).not_to receive(:call)

      result = described_class.call(**attributes.merge(sync_github: true))

      expect(result.error.code).to eq("R403-PROVISION-001")
      expect(organization.secret_provisions).to be_empty
    end
  end

  it "genera il token e lo deposita nel vault senza restituire il plaintext" do
    result = described_class.call(**attributes)

    expect(result).to be_ok
    provision = result.value
    variable = provision.secret_variable
    token = provision.token

    expect(provision).to be_ready
    expect(variable.name).to eq("CLOSEYOURIT_TOKEN")
    expect(Digest::SHA256.hexdigest(variable.value)).to eq(token.token_digest)
    expect(result.value).to be_a(Secrets::Provision)
    expect(result.value.attributes.values).not_to include(variable.value)
  end

  it "è idempotente per chiave e fingerprint uguali" do
    first = described_class.call(**attributes)

    expect do
      second = described_class.call(**attributes)
      expect(second).to be_ok
      expect(second.value).to eq(first.value)
    end.not_to change(Projects::Token, :count)
  end

  it "rifiuta il riuso della chiave con una richiesta diversa" do
    described_class.call(**attributes)

    result = described_class.call(**attributes.merge(name: "Altro token"))

    expect(result).to be_err
    expect(result.error.code).to eq("R409-PROVISION-001")
    expect(result.error.status).to eq(:conflict)
  end

  it "rifiuta una idempotency_key vuota senza creare dati" do
    expect do
      result = described_class.call(**attributes.merge(idempotency_key: "   "))
      expect(result).to be_err
      expect(result.error.code).to eq("R422-PROVISION-001")
    end.not_to change(Projects::Token, :count)
  end

  it "rifiuta scope sconosciuti prima di generare il token" do
    expect do
      result = described_class.call(**attributes.merge(scopes: [ "admin" ]))
      expect(result).to be_err
      expect(result.error.code).to eq("R422-PROVISION-005")
    end.not_to change(Projects::Token, :count)
  end

  it "fa rollback del token se la scrittura nel vault fallisce" do
    allow(Secrets::Variables::Set).to receive(:call).and_return(
      Result.err(AppError.new("vault non disponibile", code: "R422-SECRET-001"))
    )

    expect do
      result = described_class.call(**attributes)
      expect(result).to be_err
      expect(result.error.code).to eq("R422-SECRET-001")
    end.not_to change(Projects::Token, :count)
  end

  it "con sync GitHub richiede un repository configurato prima di generare il token" do
    expect do
      result = described_class.call(**attributes.merge(sync_github: true))
      expect(result).to be_err
      expect(result.error.code).to eq("R422-PROVISION-004")
    end.not_to change(Projects::Token, :count)
  end

  it "con sync GitHub accoda soltanto l'id della provision" do
    create(:github_repository, project: destination_project, sync_secrets: true,
                               staging_environment: destination_environment)

    expect do
      result = described_class.call(**attributes.merge(sync_github: true))
      expect(result).to be_ok
      expect(result.value).to be_pending_sync
    end.to have_enqueued_job(Secrets::Provisions::SyncJob).with(provision_id: kind_of(String))
  end

  it "rifiuta un repository che non mappa l'environment destinatario" do
    create(:github_repository, project: destination_project, sync_secrets: true)

    result = described_class.call(**attributes.merge(sync_github: true))

    expect(result).to be_err
    expect(result.error.code).to eq("R422-PROVISION-004")
  end
end
