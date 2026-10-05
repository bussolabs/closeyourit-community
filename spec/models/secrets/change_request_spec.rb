# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::ChangeRequest, type: :model do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:environment) { create(:environment, organization:).tap { |env| project.environments << env } }
  let(:requester) { create(:account) }

  def build_request(**attrs)
    build(:secret_change_request, project:, organization:, environment:, requested_by: requester, **attrs)
  end

  def fresh_request
    create(:secret_change_request, project:, organization:, environment:, requested_by: requester)
  end

  it "è valida con gli attributi minimi di un'azione set (nome + valore)" do
    expect(build_request(action: "set", value: "abc")).to be_valid
  end

  it "è valida per un'azione di cancellazione senza valore" do
    expect(build_request(action: "remove", value: nil)).to be_valid
  end

  describe "cifratura del valore at-rest" do
    it "non salva il valore in chiaro nella colonna grezza" do
      record = create(:secret_change_request, project:, organization:, environment:, requested_by: requester,
                                                action: "set", value: "s3cr3t-plain")

      raw = ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array([ "SELECT value FROM secrets_change_requests WHERE id = ?", record.id ])
      )

      expect(raw).not_to include("s3cr3t-plain")
      expect(record.reload.value).to eq("s3cr3t-plain") # decifrato in lettura
    end
  end

  describe "enum action" do
    it "set: il predicato dedicato è true" do
      record = build_request(action: "set", value: "x")
      expect(record.set?).to be(true)
      expect(record.remove?).to be(false)
    end

    it "remove: chiave ruby 'remove' (per non collidere con Model.delete), valore persistito 'delete'" do
      record = create(:secret_change_request, project:, organization:, environment:, requested_by: requester,
                                                action: "remove", value: nil)
      expect(record.remove?).to be(true)
      expect(record.action).to eq("remove") # lettura AR = chiave, non il valore grezzo

      raw = ActiveRecord::Base.connection.select_value(
        ActiveRecord::Base.sanitize_sql_array([ "SELECT action FROM secrets_change_requests WHERE id = ?", record.id ])
      )
      expect(raw).to eq("delete") # la colonna fisica resta "delete", come da wire/dominio
    end
  end

  describe "enum status" do
    it "default pending alla creazione" do
      expect(build_request(action: "set", value: "x").status).to eq("pending")
    end

    it "applied/rejected/cancelled sono valori validi" do
      %w[applied rejected cancelled].each do |status|
        expect(build_request(action: "set", value: "x", status:)).to be_valid
      end
    end
  end

  describe "immutabilità (attr_readonly)" do
    it "vieta la riassegnazione di project_id dopo la creazione" do
      other_project = create(:project, organization:)
      record = fresh_request

      expect { record.update(project_id: other_project.id) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect(record.reload.project_id).to eq(project.id)
    end

    it "vieta la riassegnazione di environment_id dopo la creazione" do
      other_env = create(:environment, organization:).tap { |env| project.environments << env }
      record = fresh_request

      expect { record.update(environment_id: other_env.id) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect(record.reload.environment_id).to eq(environment.id)
    end

    it "vieta la riassegnazione di organization_id dopo la creazione" do
      other_org = create(:organization)
      record = fresh_request

      expect { record.update(organization_id: other_org.id) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect(record.reload.organization_id).to eq(organization.id)
    end

    it "vieta la rinomina dopo la creazione" do
      record = fresh_request

      expect { record.update(name: "OTHER_NAME") }.to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect(record.reload.name).not_to eq("OTHER_NAME")
    end

    it "vieta il cambio di action dopo la creazione" do
      record = fresh_request

      expect { record.update(action: "remove", value: nil) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect(record.reload.set?).to be(true)
    end

    it "vieta il cambio di requested_by dopo la creazione" do
      other_account = create(:account)
      record = fresh_request

      expect { record.update(requested_by_id: other_account.id) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect(record.reload.requested_by_id).to eq(requester.id)
    end
  end

  describe "validazione name UPPER_SNAKE (riusa Secrets::Variable::NAME_FORMAT)" do
    it "rifiuta un nome assente" do
      expect(build_request(name: nil, action: "set", value: "x")).not_to be_valid
    end

    it "normalizza il nome in UPPER_SNAKE senza spazi" do
      record = build_request(name: "  lower_case  ", action: "set", value: "x")
      record.valid?
      expect(record.name).to eq("LOWER_CASE")
    end

    it "accetta un nome UPPER_SNAKE valido" do
      expect(build_request(name: "MY_SECRET", action: "set", value: "x")).to be_valid
    end

    it "rifiuta un nome con trattini" do
      expect(build_request(name: "MY-SECRET", action: "set", value: "x")).not_to be_valid
    end

    it "rifiuta un nome che inizia con una cifra" do
      expect(build_request(name: "1SECRET", action: "set", value: "x")).not_to be_valid
    end
  end

  describe "prefisso riservato (riusa Secrets::Variable::RESERVED_NAME_PREFIX)" do
    it "rifiuta un nome che inizia con GITHUB_ (bloccato anche alla CREAZIONE, non solo all'applicazione)" do
      record = build_request(name: "GITHUB_TOKEN", action: "set", value: "x")

      expect(record).not_to be_valid
      expect(record.errors[:name]).to be_present
    end

    it "rifiuta il prefisso riservato anche scritto in minuscolo (normalizzato in UPPER_SNAKE prima della validazione)" do
      expect(build_request(name: "github_token", action: "set", value: "x")).not_to be_valid
    end

    it "un nome che semplicemente CONTIENE GITHUB_ non all'inizio resta valido (solo il prefisso è vietato)" do
      expect(build_request(name: "MY_GITHUB_TOKEN", action: "set", value: "x")).to be_valid
    end
  end

  describe "tenant-integrity" do
    it "rifiuta un environment di un'altra organizzazione" do
      foreign_env = create(:environment, organization: create(:organization))
      expect(build_request(environment: foreign_env, action: "set", value: "x")).not_to be_valid
    end

    it "rifiuta una organization_id incoerente col progetto" do
      record = build_request(action: "set", value: "x")
      record.organization_id = create(:organization).id
      expect(record).not_to be_valid
      expect(record.errors[:organization_id]).to be_present
    end

    it "guard tenant: non solleva quando project/environment sono assenti" do
      expect { described_class.new.valid? }.not_to raise_error
    end
  end

  describe "presenza del valore coerente con l'azione" do
    it "set senza valore → non valida" do
      record = build_request(action: "set", value: nil)
      expect(record).not_to be_valid
      expect(record.errors[:value]).to be_present
    end

    it "set con stringa vuota esplicita → valida" do
      expect(build_request(action: "set", value: "")).to be_valid
    end

    it "remove con un valore → non valida" do
      record = build_request(action: "remove", value: "non dovrebbe esserci")
      expect(record).not_to be_valid
      expect(record.errors[:value]).to be_present
    end

    it "guard: non solleva quando action è assente" do
      expect { build_request(action: nil, value: nil).valid? }.not_to raise_error
    end
  end

  describe ".pending (scope generato dall'enum status)" do
    it "restituisce solo le richieste in stato pending" do
      pending_request = fresh_request
      applied_request = create(:secret_change_request, project:, organization:, environment:, requested_by: requester,
                                                         status: "applied")

      expect(described_class.pending).to include(pending_request)
      expect(described_class.pending).not_to include(applied_request)
    end
  end

  describe ".for_project" do
    it "filtra le richieste del solo progetto passato" do
      mine = fresh_request
      other_project = create(:project, organization:)
      other_env = create(:environment, organization:).tap { |env| other_project.environments << env }
      other = create(:secret_change_request, project: other_project, organization:, environment: other_env,
                                              requested_by: requester)

      expect(described_class.for_project(project)).to contain_exactly(mine)
      expect(described_class.for_project(project)).not_to include(other)
    end
  end

  describe ".recent" do
    it "ordina dalla più recente alla meno recente" do
      older = create(:secret_change_request, project:, organization:, environment:, requested_by: requester,
                                              created_at: 2.days.ago)
      newer = create(:secret_change_request, project:, organization:, environment:, requested_by: requester,
                                              created_at: 1.hour.ago)

      expect(described_class.recent.to_a).to eq([ newer, older ])
    end
  end
end
