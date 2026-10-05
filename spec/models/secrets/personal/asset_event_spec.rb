# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::Personal::AssetEvent do
  describe "validazioni" do
    it "accetta solo azioni note" do
      expect(build(:personal_secret_asset_event, action: "uploaded")).to be_valid
      expect(build(:personal_secret_asset_event, action: "hacked")).not_to be_valid
    end
  end

  describe ".for" do
    it "include solo gli eventi dell'account nell'organizzazione (anti-BOLA)" do
      mine = create(:personal_secret_asset_event)
      other = create(:personal_secret_asset_event, organization: mine.organization)

      scope = described_class.for(account: mine.account, organization: mine.organization)
      expect(scope).to include(mine)
      expect(scope).not_to include(other)
    end
  end

  describe "audit-safe" do
    it "sopravvive al purge dell'asset (asset nullify)" do
      asset = create(:personal_secret_asset)
      event = create(:personal_secret_asset_event, account: asset.account, organization: asset.organization, asset:)
      asset.destroy
      expect(event.reload.asset_id).to be_nil
    end
  end
end
