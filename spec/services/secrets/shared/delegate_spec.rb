# frozen_string_literal: true

require "rails_helper"

# Delegare = far leggere a un progetto un valore che vive nell'organizzazione. È il gesto che porta un
# segreto dentro un perimetro nuovo, quindi lascia traccia e, se quel progetto manda i secret a GitHub,
# fa partire l'invio: senza, il valore risulterebbe delegato qui e assente là.
RSpec.describe Secrets::Shared::Delegate do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:environment) { create(:environment, organization:, code: "production") }
  let(:project) { create(:project, organization:) }
  let(:actor) { create(:account) }

  before { create(:project_environment, project:, environment:) }

  let(:shared_value) do
    Secrets::Shared::Save.call(organization:, environment:, name: "api_key", value: "secret").value
  end

  it "collega il valore al progetto" do
    result = described_class.call(shared_value:, project:, actor:)

    expect(result).to be_ok
    expect(result.value).to be_persisted
    expect(shared_value.reload.projects).to eq([ project ])
  end

  it "lascia scritto chi ha delegato, cosa e dove" do
    expect { described_class.call(shared_value:, project:, actor:) }
      .to change { Secrets::Shared::Event.where(action: "delegated").count }.by(1)

    event = Secrets::Shared::Event.where(action: "delegated").last
    expect(event).to have_attributes(organization:, project:, actor:, environment:,
                                     shared_variable: shared_value.shared_variable)
    expect(event.name).to eq("API_KEY")
  end

  # CYRA-777 — l'alias vale anche fuori dal consolidamento: si delega un valore a un progetto che lo
  # chiama in un altro modo, senza toccare il codice di quel progetto.
  it "col nome scelto dal progetto, il bundle consegna quello" do
    result = described_class.call(shared_value:, project:, actor:, local_name: "chiave_api")

    expect(result).to be_ok
    expect(result.value.local_name).to eq("CHIAVE_API")
    expect(Secrets::Bundle.call(project:, environment:).value).to eq("CHIAVE_API" => "secret")
  end

  it "senza alias il progetto legge il nome del secret dell'organizzazione" do
    described_class.call(shared_value:, project:, actor:)

    expect(Secrets::Bundle.call(project:, environment:).value).to eq("API_KEY" => "secret")
  end

  it "senza attore la delega resta possibile e la riga lo dice" do
    expect(described_class.call(shared_value:, project:)).to be_ok
    expect(Secrets::Shared::Event.where(action: "delegated").last.actor).to be_nil
  end

  it "col progetto che manda i secret a GitHub fa partire l'invio" do
    repository = create(:github_repository, project:, sync_secrets: true)

    described_class.call(shared_value:, project:, actor:)

    expect(Secrets::Github::SyncJob).to have_been_enqueued.with(github_repository_id: repository.id)
  end

  it "col progetto che non li manda non parte niente" do
    create(:github_repository, project:, sync_secrets: false)

    described_class.call(shared_value:, project:, actor:)

    expect(Secrets::Github::SyncJob).not_to have_been_enqueued
  end

  it "delegare due volte allo stesso progetto è un errore di dominio, non un doppione" do
    described_class.call(shared_value:, project:, actor:)

    result = described_class.call(shared_value: shared_value.reload, project:, actor:)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-SHARED-002")
    expect(shared_value.reload.delegations.count).to eq(1)
  end

  it "un progetto che non dichiara quell'ambiente non riceve niente, e non resta traccia del tentativo" do
    shared_value
    senza_ambiente = create(:project, organization:)

    expect do
      expect(described_class.call(shared_value:, project: senza_ambiente, actor:)).to be_err
    end.to not_change(Secrets::Shared::Delegation, :count)
      .and not_change(Secrets::Shared::Event, :count)
  end

  it "il valore delegato entra nel pacchetto che il progetto legge" do
    described_class.call(shared_value:, project:, actor:)

    expect(Secrets::Bundle.call(project:, environment:).value).to eq("API_KEY" => "secret")
  end
end
