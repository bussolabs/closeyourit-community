# frozen_string_literal: true

require "rails_helper"

RSpec.describe Product::Features::Destroy, type: :service do
  it "elimina la funzionalità" do
    feature = create(:product_feature)

    expect { described_class.call(feature: feature) }.to change(Product::Feature, :count).by(-1)
  end

  it "elimina anche le celle della funzionalità" do
    cell = create(:feature_platform)

    expect do
      described_class.call(feature: cell.feature)
    end.to change(Connections::FeaturePlatform, :count).by(-1)
  end
end
