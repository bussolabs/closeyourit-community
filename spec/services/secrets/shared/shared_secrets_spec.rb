# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Shared organization secrets" do
  let(:organization) { create(:organization) }
  let(:environment) { create(:environment, organization:, code: "production") }
  let(:project) { create(:project, organization:) }

  before { create(:project_environment, project:, environment:) }

  def save_value(value = "one", **options)
    Secrets::Shared::Save.call(organization:, environment:, name: "api_key", value:, **options)
  end

  it "normalizza, cifra e crea versioni immutabili" do
    result = save_value
    shared = result.value

    expect(shared.name).to eq("API_KEY")
    expect(shared.value).to eq("one")
    expect(shared.ciphertext_for(:value)).not_to include("one")
    expect(shared.versions.pluck(:number)).to eq([ 1 ])
  end

  it "distingue una stringa vuota esplicita da un valore non fornito" do
    explicit_empty = save_value("")
    missing = Secrets::Shared::Save.call(organization:, environment:, name: "missing", value: nil)

    expect(explicit_empty).to be_ok
    expect(explicit_empty.value.reload.value).to eq("")
    expect(missing).to be_err
    expect(missing.error.code).to eq("R422-SHARED-001")
  end

  it "rifiuta prefissi riservati e ambienti di un altro tenant" do
    expect(Secrets::Shared::Save.call(organization:, environment:, name: "GITHUB_TOKEN", value: "x")).to be_err
    foreign_environment = create(:environment)
    expect(Secrets::Shared::Save.call(organization:, environment: foreign_environment, name: "TOKEN", value: "x")).to be_err
  end

  it "rejects names the shell or a runtime reads before any program runs (CYRA-1046)" do
    %w[PATH LD_PRELOAD DYLD_INSERT_LIBRARIES NODE_OPTIONS].each do |name|
      expect(Secrets::Shared::Save.call(organization:, environment:, name:, value: "x")).to be_err, "#{name} must be rejected"
    end
  end

  it "delega solo a target validi e include il valore nel bundle senza cambiare formato" do
    shared = save_value.value
    expect(Secrets::Shared::Delegate.call(shared_value: shared, project:).value).to be_persisted

    expect(Secrets::Bundle.call(project:, environment:).value).to eq("API_KEY" => "one")
  end

  it "rifiuta conflitti locali in entrambe le direzioni" do
    local = Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "local", enqueue_sync: false).value
    shared = save_value.value
    expect(Secrets::Shared::Delegate.call(shared_value: shared, project:)).to be_err

    local.destroy!
    Secrets::Shared::Delegate.call(shared_value: shared, project:)
    expect(Secrets::Variables::Set.call(project:, environment:, name: "API_KEY", value: "local", enqueue_sync: false)).to be_err
  end

  it "richiede un digest aggiornato per la rotazione e registra audit/versione" do
    shared = save_value.value
    Secrets::Shared::Delegate.call(shared_value: shared, project:)
    stale = save_value("two", confirmation_digest: "stale")
    expect(stale.error.code).to eq("R409-SHARED-001")
    expect(shared.reload.value).to eq("one")

    digest = Secrets::Shared::Impact.call(shared_value: shared, effect: :rotate).value["digest"]
    expect { save_value("two", confirmation_digest: digest) }
      .to change { shared.reload.versions.count }.by(1)
      .and change { Secrets::Shared::Event.where(action: "rotated").count }.by(1)
  end

  it "accetta il digest di rollback per ripristinare un valore delegato" do
    shared = save_value.value
    Secrets::Shared::Delegate.call(shared_value: shared, project:)
    rotation_digest = Secrets::Shared::Impact.call(shared_value: shared, effect: :rotate).value["digest"]
    save_value("two", confirmation_digest: rotation_digest)
    previous = shared.versions.find_by!(number: 1)
    rollback_digest = Secrets::Shared::Impact.call(shared_value: shared, effect: :rollback).value["digest"]

    result = save_value(previous.value, confirmation_digest: rollback_digest,
                        confirmation_effect: :rollback, action: "rolled_back")

    expect(result).to be_ok
    expect(shared.reload.value).to eq("one")
    expect(Secrets::Shared::Event.where(action: "rolled_back", shared_variable: shared.shared_variable)).to exist
  end

  it "rifiuta una delega se capability secrets è disabilitata" do
    project.project_environments.first.update!(secrets_enabled: false)
    expect(Secrets::Shared::Delegate.call(shared_value: save_value.value, project:)).to be_err
  end
end
