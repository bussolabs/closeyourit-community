# frozen_string_literal: true

require "rails_helper"

RSpec.describe Accounts::ApiTokens::RevokeAll, type: :service do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }

  before { create(:membership, account:, organization:) }

  describe "#call" do
    it "revoca tutti i token attivi dell'account" do
      first = create(:api_token, account:, organization:)
      second = create(:api_token, account:, organization:)

      result = described_class.call(account:)

      expect(result).to be_ok
      expect(result.value).to eq(2)
      expect(first.reload.revoked?).to be(true)
      expect(second.reload.revoked?).to be(true)
    end

    it "non tocca i token di un altro account" do
      altrui = create(:api_token)

      described_class.call(account:)

      expect(altrui.reload.revoked?).to be(false)
    end

    it "non riscrive revoked_at di un token già revocato" do
      token = create(:api_token, :revoked, account:, organization:)
      original = token.revoked_at

      described_class.call(account:)

      expect(token.reload.revoked_at).to be_within(1.second).of(original)
    end

    it "esclude il token indicato in keep (revoca tutti gli altri)" do
      keep = create(:api_token, account:, organization:)
      other = create(:api_token, account:, organization:)

      result = described_class.call(account:, keep: keep)

      expect(result.value).to eq(1)
      expect(keep.reload.revoked?).to be(false)
      expect(other.reload.revoked?).to be(true)
    end

    it "senza token attivi ritorna zero" do
      result = described_class.call(account:)
      expect(result).to be_ok
      expect(result.value).to eq(0)
    end
  end
end
