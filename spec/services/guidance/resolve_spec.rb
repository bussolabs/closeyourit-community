# frozen_string_literal: true

require "rails_helper"

RSpec.describe Guidance::Resolve do
  let(:organization) { create(:organization) }
  let(:group) { create(:group, organization:) }
  let(:project) { create(:project, organization:, group:) }

  def resolve = described_class.call(project:)

  describe "Scenario 1: gerarchia" do
    it "compone i tre livelli con key distinte, con origine e ordine deterministici" do
      create(:guidance_reference, owner: organization, key: "org-repo", position: 0)
      create(:guidance_reference, owner: group, key: "group-repo", position: 1)
      create(:guidance_reference, owner: project, key: "proj-repo", position: 2)

      references = resolve.references

      expect(references.map(&:key)).to eq(%w[org-repo group-repo proj-repo])
      expect(references.map(&:level)).to eq(%w[organization group project])
    end

    it "eredita al progetto una key definita solo a livello organizzazione" do
      create(:guidance_reference, owner: organization, key: "repo")

      references = resolve.references

      expect(references.map(&:key)).to eq(%w[repo])
      expect(references.first.level).to eq("organization")
    end

    it "salta il livello gruppo quando il progetto non ne ha" do
      standalone = create(:project, organization:, group: nil)
      create(:guidance_reference, owner: organization, key: "org-repo")
      create(:guidance_reference, owner: standalone, key: "proj-repo")

      references = described_class.call(project: standalone).references

      expect(references.map(&:key)).to contain_exactly("org-repo", "proj-repo")
    end

    it "ordina gli elementi risolti per position poi key" do
      create(:guidance_reference, owner: organization, key: "zzz", position: 0)
      create(:guidance_reference, owner: project, key: "aaa", position: 5)

      expect(resolve.references.map(&:key)).to eq(%w[zzz aaa])
    end
  end

  describe "Scenario 2: override" do
    it "una key ridefinita al progetto sostituisce quella dell'organizzazione (replace)" do
      create(:guidance_reference, owner: organization, key: "repo", location: "git@org")
      create(:guidance_reference, owner: project, key: "repo", location: "git@project")

      references = resolve.references

      expect(references.size).to eq(1)
      expect(references.first.location).to eq("git@project")
      expect(references.first.level).to eq("project")
    end

    it "una reference disabilitata al progetto esclude quella ereditata (disable)" do
      create(:guidance_reference, owner: organization, key: "repo")
      create(:guidance_reference, :disabled, owner: project, key: "repo")

      expect(resolve.references.map(&:key)).not_to include("repo")
    end

    it "non lascia duplicati ambigui quando la stessa key è ai tre livelli" do
      create(:guidance_reference, owner: organization, key: "repo")
      create(:guidance_reference, owner: group, key: "repo")
      create(:guidance_reference, owner: project, key: "repo")

      expect(resolve.references.map(&:key)).to eq(%w[repo])
    end
  end

  describe "procedure: composizione del contenuto" do
    it "accoda i contenuti lungo la gerarchia con merge_strategy append" do
      create(:guidance_procedure, :append, owner: organization, key: "flow", content: "Passo org")
      create(:guidance_procedure, :append, owner: project, key: "flow", content: "Passo progetto")

      procedures = resolve.procedures

      expect(procedures.size).to eq(1)
      expect(procedures.first.content).to eq("Passo org\n\nPasso progetto")
      expect(procedures.first.level).to eq("project")
    end

    it "con merge_strategy override tiene solo il contenuto del livello più vicino" do
      create(:guidance_procedure, owner: organization, key: "flow", content: "Passo org")
      create(:guidance_procedure, owner: project, key: "flow", content: "Passo progetto")

      expect(resolve.procedures.first.content).to eq("Passo progetto")
    end

    it "application_mode replace taglia la catena di merge ereditata" do
      create(:guidance_procedure, :append, owner: organization, key: "flow", content: "Passo org")
      create(:guidance_procedure, :replace, owner: project, key: "flow", content: "Solo progetto")

      expect(resolve.procedures.first.content).to eq("Solo progetto")
    end

    it "application_mode disable esclude la procedura ereditata" do
      create(:guidance_procedure, owner: organization, key: "flow", content: "Passo org")
      create(:guidance_procedure, :disable, owner: project, key: "flow", content: "ignorato")

      expect(resolve.procedures.map(&:key)).not_to include("flow")
    end

    it "una procedura disabilitata esclude la key ereditata" do
      create(:guidance_procedure, owner: organization, key: "flow", content: "Passo org")
      create(:guidance_procedure, :disabled, owner: project, key: "flow", content: "ignorato")

      expect(resolve.procedures.map(&:key)).not_to include("flow")
    end
  end

  describe "isolamento tenant" do
    it "ignora la guidance di un'altra organizzazione" do
      create(:guidance_reference, owner: organization, key: "repo")
      other_project = create(:project)
      create(:guidance_reference, owner: other_project, key: "repo")

      expect(resolve.references.size).to eq(1)
    end
  end

  describe "assenza di guidance" do
    it "restituisce collezioni vuote senza errori" do
      resolution = resolve

      expect(resolution.references).to eq([])
      expect(resolution.procedures).to eq([])
    end
  end
end
