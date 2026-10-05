# frozen_string_literal: true

require "rails_helper"

RSpec.describe Product::Categories::Destroy, type: :service do
  it "elimina una categoria vuota" do
    category = create(:product_category)

    expect { described_class.call(category: category) }.to change(Product::Category, :count).by(-1)
  end

  it "blocca l'eliminazione di una categoria che contiene funzionalità" do
    feature = create(:product_feature)

    result = described_class.call(category: feature.category)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-PRODUCT-004")
    expect(feature.reload).to be_persisted
  end
end
