# frozen_string_literal: true

require "rails_helper"

RSpec.describe Authorization::Catalog do
  describe ".keys" do
    it "include le chiavi scoped e org-level note" do
      expect(described_class.keys).to include(
        "tickets.edit", "errors.triage", "tokens.manage", "secrets.provision", # scoped
        "members.manage", "permissions.manage", "projects.create" # org-level
      )
    end

    it "non ha duplicati" do
      expect(described_class.keys).to eq(described_class.keys.uniq)
    end
  end

  describe ".valid?" do
    it "vero per una chiave del catalogo" do
      expect(described_class.valid?("tickets.edit")).to be true
    end

    it "falso per una chiave sconosciuta" do
      expect(described_class.valid?("tickets.teleport")).to be false
    end

    it "falso per nil/blank" do
      expect(described_class.valid?(nil)).to be false
      expect(described_class.valid?("")).to be false
    end
  end

  describe ".scoped?" do
    it "vero per un permesso per-progetto" do
      expect(described_class.scoped?("tickets.edit")).to be true
    end

    it "falso per un permesso org-level" do
      expect(described_class.scoped?("members.manage")).to be false
    end
  end

  describe ".all" do
    it "ogni voce ha key, area e flag scoped" do
      described_class.all.each do |entry|
        expect(entry).to have_key(:key)
        expect(entry).to have_key(:area)
        expect([ true, false ]).to include(entry[:scoped])
      end
    end
  end

  describe ".by_area" do
    it "raggruppa le chiavi per area (per la UI dei ruoli)" do
      grouped = described_class.by_area
      expect(grouped).to be_a(Hash)
      expect(grouped.values.flatten).to match_array(described_class.all)
    end
  end
end
