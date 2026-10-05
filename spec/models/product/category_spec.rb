# frozen_string_literal: true

require "rails_helper"

RSpec.describe Product::Category, type: :model do
  describe "factory" do
    it "produce una categoria valida" do
      expect(build(:product_category)).to be_valid
    end
  end

  describe "validazioni" do
    it "richiede il nome" do
      expect(build(:product_category, name: nil)).not_to be_valid
    end

    it "normalizza il nome" do
      expect(create(:product_category, name: "  Auth  ").name).to eq("Auth")
    end

    it "rifiuta due categorie con lo stesso nome nello stesso prodotto" do
      group = create(:group)
      create(:product_category, group: group, name: "Auth")
      expect(build(:product_category, group: group, organization: group.organization, name: "auth")).not_to be_valid
    end

    it "permette lo stesso nome in prodotti diversi" do
      create(:product_category, name: "Auth")
      expect(build(:product_category, name: "Auth")).to be_valid
    end

    it "rifiuta un'organizzazione diversa da quella del prodotto" do
      category = build(:product_category, group: create(:group), organization: create(:organization))
      expect(category).not_to be_valid
    end
  end

  describe "scope" do
    it ".ordered ordina per position poi nome" do
      group = create(:group)
      second = create(:product_category, group: group, organization: group.organization, position: 2)
      first = create(:product_category, group: group, organization: group.organization, position: 1)
      expect(described_class.where(group: group).ordered.to_a).to eq([ first, second ])
    end
  end

  describe "cancellazione" do
    it "cancella anche le funzionalità che contiene" do
      feature = create(:product_feature)
      expect { feature.category.destroy }.to change(Product::Feature, :count).by(-1)
    end
  end
end
