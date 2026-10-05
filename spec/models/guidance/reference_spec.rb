# frozen_string_literal: true

require "rails_helper"

RSpec.describe Guidance::Reference, type: :model do
  describe "factory" do
    it "è valida di default" do
      expect(build(:guidance_reference)).to be_valid
    end
  end

  describe "validazioni" do
    it "richiede la key" do
      expect(build(:guidance_reference, key: nil)).not_to be_valid
    end

    it "rifiuta una key con formato non valido" do
      expect(build(:guidance_reference, key: "Non Valida!")).not_to be_valid
    end

    it "normalizza la key a minuscolo senza spazi ai bordi" do
      reference = create(:guidance_reference, key: "  Repo-Main  ")
      expect(reference.key).to eq("repo-main")
    end

    it "rifiuta una reference senza location (è un puntatore a una fonte)" do
      expect(build(:guidance_reference, location: "   ")).not_to be_valid
    end

    it "normalizza la location togliendo gli spazi ai bordi" do
      reference = create(:guidance_reference, location: "  git@repo  ")
      expect(reference.location).to eq("git@repo")
    end

    it "rifiuta un owner_type fuori dalla whitelist" do
      reference = build(:guidance_reference)
      reference.owner_type = "Accounts::Account"
      expect(reference).not_to be_valid
      expect(reference.errors[:owner_type]).to be_present
    end

    it "impedisce due reference con la stessa key sullo stesso owner" do
      project = create(:project)
      create(:guidance_reference, owner: project, key: "repo")
      duplicate = build(:guidance_reference, owner: project, key: "repo")
      expect(duplicate).not_to be_valid
    end

    it "consente la stessa key su owner diversi (la gerarchia vive nei livelli)" do
      organization = create(:organization)
      project = create(:project, organization:)
      create(:guidance_reference, owner: organization, organization:, key: "repo")
      twin = build(:guidance_reference, owner: project, organization:, key: "repo")
      expect(twin).to be_valid
    end
  end

  describe "kind" do
    it "espone i quattro tipi di fonte" do
      expect(described_class.kinds.keys).to contain_exactly("repository", "knowledge_base", "url", "path")
    end
  end

  describe "integrità tenant" do
    it "rifiuta un'organizzazione diversa da quella dell'owner" do
      project = create(:project)
      other_org = create(:organization)
      reference = build(:guidance_reference, owner: project, organization: other_org)
      expect(reference).not_to be_valid
      expect(reference.errors[:organization]).to be_present
    end

    it "accetta un'organizzazione come owner (org di livello)" do
      organization = create(:organization)
      reference = build(:guidance_reference, owner: organization, organization:)
      expect(reference).to be_valid
    end
  end

  describe ".ordered" do
    it "ordina per position poi key" do
      organization = create(:organization)
      second = create(:guidance_reference, owner: organization, organization:, position: 1, key: "b")
      first  = create(:guidance_reference, owner: organization, organization:, position: 0, key: "a")
      expect(described_class.ordered).to eq([ first, second ])
    end
  end
end
