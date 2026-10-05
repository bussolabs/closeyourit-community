# frozen_string_literal: true

require "rails_helper"

RSpec.describe Product::Feature, type: :model do
  describe "factory" do
    it "produce una funzionalità valida" do
      expect(build(:product_feature)).to be_valid
    end

    it "produce una funzionalità documentata valida" do
      expect(build(:product_feature, :documented)).to be_valid
    end
  end

  describe "validazioni" do
    it "richiede il nome" do
      expect(build(:product_feature, name: nil)).not_to be_valid
    end

    it "rifiuta due funzionalità con lo stesso nome nella stessa categoria" do
      category = create(:product_category)
      create(:product_feature, category: category, organization: category.organization, name: "2FA")
      expect(build(:product_feature, category: category, organization: category.organization, name: "2fa")).not_to be_valid
    end

    it "permette lo stesso nome in categorie diverse" do
      create(:product_feature, name: "2FA")
      expect(build(:product_feature, name: "2FA")).to be_valid
    end

    it "rifiuta un'organizzazione diversa da quella della categoria" do
      feature = build(:product_feature, category: create(:product_category), organization: create(:organization))
      expect(feature).not_to be_valid
    end

    it "rifiuta una pagina della base di conoscenza di un'altra organizzazione" do
      feature = create(:product_feature)
      feature.knowledge_page = create(:knowledge_page, organization: create(:organization))
      expect(feature).not_to be_valid
    end
  end

  describe "#group_id" do
    it "delega al prodotto della categoria" do
      feature = create(:product_feature)
      expect(feature.group_id).to eq(feature.category.group_id)
    end
  end

  describe "cancellazione" do
    it "cancella anche le sue celle" do
      cell = create(:feature_platform)
      expect { cell.feature.destroy }.to change(Connections::FeaturePlatform, :count).by(-1)
    end
  end
end
