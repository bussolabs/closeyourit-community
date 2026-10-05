# frozen_string_literal: true

require "rails_helper"

# Preview del contesto EFFETTIVO di un progetto per la UI member (CYRA-75). Affianca Guidance::Resolve
# (fonte del risolto/CLI) annotando lo stato di ogni key rispetto al progetto: definita qui, ereditata,
# sostituita (override) o disabilitata — con la sua origine.
RSpec.describe Guidance::Preview do
  let(:organization) { create(:organization) }
  let(:group) { create(:group, organization:) }
  let(:project) { create(:project, organization:, group:) }

  def preview = described_class.call(project:)

  describe "references" do
    it "una key definita solo in alto è ereditata, con l'origine del livello che la definisce" do
      create(:guidance_reference, owner: organization, key: "org-repo", location: "git@org")

      row = preview.references.find { |r| r.key == "org-repo" }

      expect(row.status).to eq(:inherited)
      expect(row.origin).to eq("organization")
      expect(row.location).to eq("git@org")
    end

    it "una key definita solo al progetto è definita qui" do
      create(:guidance_reference, owner: project, key: "proj-only")

      row = preview.references.find { |r| r.key == "proj-only" }

      expect(row.status).to eq(:here)
      expect(row.origin).to eq("project")
    end

    it "una key ridefinita al progetto sostituisce quella ereditata (override), con il valore locale" do
      create(:guidance_reference, owner: organization, key: "repo", location: "git@org")
      create(:guidance_reference, owner: project, key: "repo", location: "git@project")

      row = preview.references.find { |r| r.key == "repo" }

      expect(row.status).to eq(:overridden)
      expect(row.origin).to eq("project")
      expect(row.location).to eq("git@project")
    end

    it "una key ereditata e disabilitata al progetto risulta disabilitata (fuori dal risolto)" do
      create(:guidance_reference, owner: organization, key: "legacy")
      create(:guidance_reference, :disabled, owner: project, key: "legacy")

      row = preview.references.find { |r| r.key == "legacy" }

      expect(row.status).to eq(:disabled)
      expect(row.origin).to eq("project")
    end

    it "ordina le righe per position poi key (deterministico)" do
      create(:guidance_reference, owner: organization, key: "zzz", position: 0)
      create(:guidance_reference, owner: project, key: "aaa", position: 5)

      expect(preview.references.map(&:key)).to eq(%w[zzz aaa])
    end

    it "porta i metadati della reference risolta (kind, required)" do
      create(:guidance_reference, :url, :required, owner: organization, key: "docs", location: "https://x")

      row = preview.references.find { |r| r.key == "docs" }

      expect(row.kind).to eq("url")
      expect(row.required).to be(true)
    end
  end

  describe "procedures" do
    it "una procedura definita solo in alto è ereditata" do
      create(:guidance_procedure, owner: organization, key: "setup", content: "Installa")

      row = preview.procedures.find { |p| p.key == "setup" }

      expect(row.status).to eq(:inherited)
      expect(row.origin).to eq("organization")
      expect(row.content).to eq("Installa")
    end

    it "una procedura in replace al progetto sostituisce quella ereditata, col contenuto locale" do
      create(:guidance_procedure, owner: organization, key: "deploy", content: "org")
      create(:guidance_procedure, :replace, owner: project, key: "deploy", content: "project")

      row = preview.procedures.find { |p| p.key == "deploy" }

      expect(row.status).to eq(:overridden)
      expect(row.origin).to eq("project")
      expect(row.content).to eq("project")
    end

    it "una procedura in append al progetto accoda l'ereditata (stato appended, non overridden)" do
      create(:guidance_procedure, owner: organization, key: "rules", content: "org")
      create(:guidance_procedure, :append, owner: project, key: "rules", content: "project")

      row = preview.procedures.find { |p| p.key == "rules" }

      expect(row.status).to eq(:appended)
      expect(row.origin).to eq("project")
      expect(row.content).to eq("org\n\nproject")
    end

    it "una procedura definita solo al progetto è definita qui" do
      create(:guidance_procedure, owner: project, key: "proj-proc")

      row = preview.procedures.find { |p| p.key == "proj-proc" }

      expect(row.status).to eq(:here)
      expect(row.origin).to eq("project")
    end

    it "una procedura ereditata e disabilitata al progetto risulta disabilitata" do
      create(:guidance_procedure, owner: organization, key: "old")
      create(:guidance_procedure, :disable, owner: project, key: "old")

      row = preview.procedures.find { |p| p.key == "old" }

      expect(row.status).to eq(:disabled)
    end
  end

  it "un progetto senza guidance ha preview vuote" do
    expect(preview.references).to eq([])
    expect(preview.procedures).to eq([])
  end

  it "non mostra la guidance di un altro progetto/organizzazione (isolamento tenant)" do
    other = create(:project)
    create(:guidance_reference, owner: other, key: "altrui")

    expect(preview.references).to eq([])
  end
end
