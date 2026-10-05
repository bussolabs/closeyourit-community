# frozen_string_literal: true

require "rails_helper"

# Scrivere un valore condiviso dell'organizzazione. Tre proprietà valgono la prova dedicata: il valore
# si versiona solo quando cambia davvero, la conferma legata alla fotografia dell'impatto si chiede
# solo quando qualcuno quel valore lo sta già ricevendo, e l'invio verso GitHub parte DOPO il commit,
# per ogni progetto che riceve il valore.
RSpec.describe Secrets::Shared::Save do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:environment) { create(:environment, organization:, code: "production") }
  let(:project) { create(:project, organization:) }
  let(:actor) { create(:account) }

  before { create(:project_environment, project:, environment:) }

  def salva(value = "primo", name: "api_key", **options)
    described_class.call(organization:, environment:, name:, value:, **options)
  end

  describe "la prima scrittura" do
    it "crea variabile, valore, prima versione ed evento" do
      result = salva("primo", actor:)

      expect(result).to be_ok
      value_record = result.value
      expect(value_record.name).to eq("API_KEY")
      expect(value_record.value).to eq("primo")
      expect(value_record.version_number).to eq(1)
      expect(value_record.versions.pluck(:number, :value)).to eq([ [ 1, "primo" ] ])

      event = Secrets::Shared::Event.last
      expect(event).to have_attributes(action: "created", organization:, environment:, actor:)
      expect(event.metadata).to include("version" => 1)
    end

    it "normalizza il nome: spazi via, tutto maiuscolo" do
      expect(salva("x", name: "  api_key_2  ").value.name).to eq("API_KEY_2")
    end

    it "registra chi l'ha creata" do
      expect(salva("x", actor:).value.shared_variable.created_by).to eq(actor)
    end

    it "salva la descrizione quando c'è" do
      expect(salva("x", description: "chiave del gateway").value.shared_variable.description)
        .to eq("chiave del gateway")
    end
  end

  describe "le scritture successive" do
    it "una descrizione non passata NON cancella quella che c'era" do
      salva("x", description: "chiave del gateway", actor:)

      salva("y", actor:)

      expect(Secrets::Shared::Variable.find_by(name: "API_KEY").description).to eq("chiave del gateway")
    end

    it "il primo autore resta il primo autore" do
      salva("x", actor:)

      salva("y", actor: create(:account))

      expect(Secrets::Shared::Variable.find_by(name: "API_KEY").created_by).to eq(actor)
    end

    it "cambiare valore aggiunge una versione e lo dice come rotazione" do
      salva("primo", actor:)

      result = salva("secondo", actor:)

      expect(result.value.version_number).to eq(2)
      expect(result.value.versions.order(:number).pluck(:value)).to eq(%w[primo secondo])
      expect(Secrets::Shared::Event.where(action: "rotated").count).to eq(1)
    end

    # Salvare lo stesso valore è un no-op: versionarlo gonfierebbe la cronologia e, con le
    # delegazioni attive, farebbe ripartire l'invio verso GitHub per niente.
    it "riscrivere lo STESSO valore non versiona, non registra e non manda niente" do
      salva("primo", actor:)
      create(:github_repository, project:, sync_secrets: true)
      Secrets::Shared::Delegate.call(shared_value: Secrets::Shared::Value.first, project:)
      clear_enqueued_jobs

      expect { expect(salva("primo", actor:)).to be_ok }
        .to not_change(Secrets::Shared::Version, :count)
        .and not_change { Secrets::Shared::Event.where(action: "rotated").count }
      expect(Secrets::Github::SyncJob).not_to have_been_enqueued
    end

    it "l'azione da scrivere si può dichiarare: un ripristino non è una rotazione" do
      salva("primo", actor:)

      salva("secondo", actor:, action: "rolled_back")

      expect(Secrets::Shared::Event.where(action: "rolled_back")).to exist
      expect(Secrets::Shared::Event.where(action: "rotated")).not_to exist
    end
  end

  describe "la conferma dell'impatto" do
    let(:shared_value) { salva("primo", actor:).value }

    before do
      shared_value
      Secrets::Shared::Delegate.call(shared_value:, project:)
    end

    def digest(effect: :rotate)
      Secrets::Shared::Impact.call(shared_value: shared_value.reload, effect:).value["digest"]
    end

    it "con la conferma giusta il valore cambia" do
      expect(salva("secondo", actor:, confirmation_digest: digest)).to be_ok
      expect(shared_value.reload.value).to eq("secondo")
    end

    it "con una conferma vecchia rifiuta e mostra l'impatto aggiornato" do
      result = salva("secondo", actor:, confirmation_digest: "vecchio")

      expect(result).to be_err
      expect(result.error.code).to eq("R409-SHARED-001")
      expect(result.error.details["projects"].map { |row| row["id"] }).to eq([ project.id ])
      expect(shared_value.reload.value).to eq("primo")
      expect(shared_value.versions.count).to eq(1)
    end

    it "senza conferma affatto rifiuta invece di cambiare in silenzio" do
      expect(salva("secondo", actor:)).to be_err
      expect(shared_value.reload.value).to eq("primo")
    end

    # La conferma di una rotazione non vale per un ripristino: sono due decisioni diverse.
    it "la conferma di un altro effetto non vale" do
      expect(salva("secondo", actor:, confirmation_digest: digest(effect: :rollback))).to be_err
      expect(salva("secondo", actor:, confirmation_digest: digest(effect: :rollback),
                              confirmation_effect: :rollback)).to be_ok
    end

    it "chi salta la conferma di proposito passa" do
      expect(salva("secondo", actor:, skip_confirmation: true)).to be_ok
    end

    it "un valore che nessuno riceve ancora non chiede nessuna conferma" do
      expect(described_class.call(organization:, environment:, name: "altro", value: "x", actor:)).to be_ok
    end
  end

  describe "l'invio verso GitHub" do
    it "parte per ogni progetto che riceve il valore e ha l'invio acceso" do
      shared_value = salva("primo", actor:).value
      acceso = create(:github_repository, project:, sync_secrets: true)
      altro = create(:project, organization:)
      create(:project_environment, project: altro, environment:)
      create(:github_repository, project: altro, sync_secrets: false)
      [ project, altro ].each { |target| Secrets::Shared::Delegate.call(shared_value:, project: target) }
      clear_enqueued_jobs

      salva("secondo", actor:, skip_confirmation: true)

      expect(Secrets::Github::SyncJob).to have_been_enqueued.once
        .with(github_repository_id: acceso.id)
    end

    it "chi chiede di non mandarlo non lo manda" do
      shared_value = salva("primo", actor:).value
      create(:github_repository, project:, sync_secrets: true)
      Secrets::Shared::Delegate.call(shared_value:, project:)
      clear_enqueued_jobs

      salva("secondo", actor:, skip_confirmation: true, enqueue_sync: false)

      expect(Secrets::Github::SyncJob).not_to have_been_enqueued
    end
  end

  it "un valore mai fornito è un errore di dominio, non una riga vuota" do
    result = described_class.call(organization:, environment:, name: "api_key", value: nil)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-SHARED-001")
    expect(Secrets::Shared::Value.count).to eq(0)
  end

  it "una stringa vuota scritta apposta è un valore valido" do
    result = salva("")

    expect(result).to be_ok
    expect(result.value.reload.value).to eq("")
  end
end
