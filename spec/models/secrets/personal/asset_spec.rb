# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::Personal::Asset do
  describe "validazioni" do
    it "richiede un nome" do
      asset = build(:personal_secret_asset, name: nil)
      expect(asset).not_to be_valid
      expect(asset.errors[:name]).to be_present
    end

    it "rifiuta un nome fatto di soli spazi (normalizzato a vuoto)" do
      asset = build(:personal_secret_asset, name: "   ")
      expect(asset).not_to be_valid
    end

    it "richiede un asset_type" do
      asset = build(:personal_secret_asset, asset_type: nil)
      expect(asset).not_to be_valid
      expect(asset.errors[:asset_type]).to be_present
    end

    it "impone l'unicità del nome per [account, organization]" do
      existing = create(:personal_secret_asset, name: "id_rsa")
      dup = build(:personal_secret_asset, account: existing.account, organization: existing.organization, name: "id_rsa")
      expect(dup).not_to be_valid
      expect(dup.errors[:name]).to be_present
    end

    it "consente lo stesso nome ad account diversi nella stessa org" do
      first = create(:personal_secret_asset, name: "id_rsa")
      other = build(:personal_secret_asset, organization: first.organization, name: "id_rsa")
      expect(other).to be_valid
    end
  end

  describe "immutabilità dello scope" do
    it "non riassegna account_id/organization_id (attr_readonly)" do
      asset = create(:personal_secret_asset)
      other_account = create(:account)
      expect { asset.update(account_id: other_account.id) }.to raise_error(ActiveRecord::ReadonlyAttributeError)
      expect(asset.reload.account_id).not_to eq(other_account.id)
    end
  end

  describe ".for" do
    it "include solo i file dell'account nell'organizzazione (anti-BOLA)" do
      mine = create(:personal_secret_asset)
      other_account = create(:personal_secret_asset, organization: mine.organization)
      other_org = create(:personal_secret_asset, account: mine.account)

      scope = described_class.for(account: mine.account, organization: mine.organization)
      expect(scope).to include(mine)
      expect(scope).not_to include(other_account)
      expect(scope).not_to include(other_org)
    end
  end

  describe "versioni" do
    it "espone current_version con 0, 1 o N versioni" do
      asset = create(:personal_secret_asset)
      expect(asset.current_version).to be_nil

      v1 = create(:personal_secret_asset_version, asset:, number: 1)
      expect(asset.reload.current_version).to eq(v1)

      v2 = create(:personal_secret_asset_version, asset:, number: 2)
      expect(asset.reload.current_version).to eq(v2)
    end

    it "distrugge le versioni con l'asset (dependent: destroy)" do
      asset = create(:personal_secret_asset)
      create(:personal_secret_asset_version, asset:, number: 1)
      expect { asset.destroy }.to change(Secrets::Personal::AssetVersion, :count).by(-1)
    end
  end

  describe "#archived?" do
    it "è vero solo quando archived_at è valorizzato" do
      expect(build(:personal_secret_asset, archived_at: nil)).not_to be_archived
      expect(build(:personal_secret_asset, archived_at: Time.current)).to be_archived
    end
  end
end
