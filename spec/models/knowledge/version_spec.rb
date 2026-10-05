# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Version, type: :model do
  describe "validazioni" do
    it "è valida con pagina, organizzazione, numero, titolo e corpo" do
      expect(build(:knowledge_version)).to be_valid
    end

    it "richiede numero, titolo e corpo" do
      expect(build(:knowledge_version, number: nil)).not_to be_valid
      expect(build(:knowledge_version, title: nil)).not_to be_valid
      expect(build(:knowledge_version, body: nil)).not_to be_valid
    end

    it "richiede numero unico per pagina, ma lo consente su pagine diverse" do
      page = create(:knowledge_page)
      create(:knowledge_version, page: page, organization: page.project.organization, number: 1)

      collisione = build(:knowledge_version, page: page, organization: page.project.organization, number: 1)
      expect(collisione).not_to be_valid

      altra_pagina = build(:knowledge_version, number: 1)
      expect(altra_pagina).to be_valid
    end
  end

  describe "kind" do
    it "espone note/decision/guide" do
      expect(build(:knowledge_version, kind: :decision)).to be_valid
      expect(build(:knowledge_version, kind: :guide)).to be_valid
    end

    it "rifiuta un kind fuori enum" do
      expect { build(:knowledge_version, kind: :poesia) }.to raise_error(ArgumentError)
    end
  end

  describe "integrità tenant" do
    it "rifiuta un'organizzazione diversa da quella della pagina" do
      page = create(:knowledge_page)
      versione = build(:knowledge_version, page: page, organization: create(:organization))
      expect(versione).not_to be_valid
      expect(versione.errors[:organization]).to be_present
    end
  end

  describe "immutabilità (attr_readonly)" do
    it "solleva quando si tenta di riscrivere il contenuto di uno snapshot persistito" do
      versione = create(:knowledge_version, title: "Originale", body: "Corpo originale")

      expect { versione.update(title: "Modificato") }.to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect(versione.reload.title).to eq("Originale")
    end

    it "congela anche tech_spec: lo snapshot tecnico non si riscrive" do
      versione = create(:knowledge_version, tech_spec: "Dettagli tecnici originali")

      expect { versione.update(tech_spec: "Modificato") }.to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect(versione.reload.tech_spec).to eq("Dettagli tecnici originali")
    end
  end

  describe ".chronological" do
    it "ordina per numero crescente" do
      page = create(:knowledge_page)
      org = page.project.organization
      v3 = create(:knowledge_version, page: page, organization: org, number: 3)
      v1 = create(:knowledge_version, page: page, organization: org, number: 1)
      v2 = create(:knowledge_version, page: page, organization: org, number: 2)

      expect(page.versions.chronological.to_a).to eq([ v1, v2, v3 ])
    end
  end

  describe "relazione con la pagina" do
    it "cade con la pagina (dependent: destroy)" do
      page = create(:knowledge_page)
      org = page.project.organization
      create(:knowledge_version, page: page, organization: org, number: 1)
      create(:knowledge_version, page: page, organization: org, number: 2)

      expect { page.destroy }.to change(described_class, :count).by(-2)
    end

    it "espone il numero della versione live via Page#current_version_number" do
      page = create(:knowledge_page)
      org = page.project.organization
      create(:knowledge_version, page: page, organization: org, number: 1)
      create(:knowledge_version, page: page, organization: org, number: 2)

      expect(page.current_version_number).to eq(2)
    end
  end
end
