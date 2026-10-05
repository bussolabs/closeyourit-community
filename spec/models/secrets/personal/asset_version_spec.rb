# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::Personal::AssetVersion do
  describe "validazioni" do
    it "richiede un numero intero positivo" do
      expect(build(:personal_secret_asset_version, number: 0)).not_to be_valid
      expect(build(:personal_secret_asset_version, number: 1)).to be_valid
    end

    it "impone l'unicità del numero per asset" do
      version = create(:personal_secret_asset_version, number: 1)
      dup = build(:personal_secret_asset_version, asset: version.asset, number: 1)
      expect(dup).not_to be_valid
    end

    it "richiede i campi dell'envelope crittografico" do
      version = build(:personal_secret_asset_version, wrapped_key: nil, fingerprint: nil)
      expect(version).not_to be_valid
      expect(version.errors[:wrapped_key]).to be_present
      expect(version.errors[:fingerprint]).to be_present
    end

    it "accetta byte_size fino al cap di 10 MB ed esclude oltre" do
      cap = 10.megabytes
      expect(build(:personal_secret_asset_version, byte_size: cap - 1)).to be_valid
      expect(build(:personal_secret_asset_version, byte_size: cap)).to be_valid
      expect(build(:personal_secret_asset_version, byte_size: cap + 1)).not_to be_valid
      expect(build(:personal_secret_asset_version, byte_size: 0)).not_to be_valid
    end
  end

  describe "#aad" do
    it "lega la versione al suo contenuto con la label del dominio personale" do
      version = build(:personal_secret_asset_version, number: 3, original_filename: "id_rsa",
                      content_type: "application/octet-stream", byte_size: 42)
      expect(version.aad).to start_with("personal-secret-asset:")
      expect(version.aad).to include(":version:3:id_rsa:application/octet-stream:42")
    end
  end
end
