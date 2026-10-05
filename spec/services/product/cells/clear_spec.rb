# frozen_string_literal: true

require "rails_helper"

RSpec.describe Product::Cells::Clear, type: :service do
  it "rimuove la cella" do
    cell = create(:feature_platform)

    expect do
      described_class.call(feature: cell.feature, platform: cell.platform)
    end.to change(Connections::FeaturePlatform, :count).by(-1)
  end

  it "non è un errore azzerare una cella mai impostata" do
    feature = create(:product_feature)
    platform = create(:platform, organization: feature.organization)

    result = described_class.call(feature: feature, platform: platform)

    expect(result).to be_ok
    expect(result.value).to be_nil
  end
end
