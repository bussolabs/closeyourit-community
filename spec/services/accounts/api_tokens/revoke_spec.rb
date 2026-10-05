require "rails_helper"

RSpec.describe Accounts::ApiTokens::Revoke, type: :service do
  describe "#call" do
    it "imposta revoked_at sul token" do
      token = create(:api_token)
      result = described_class.call(token:)

      expect(result).to be_ok
      expect(token.reload.revoked?).to be(true)
    end

    it "è idempotente: ri-revocare non cambia revoked_at" do
      token = create(:api_token, :revoked)
      original = token.revoked_at

      result = described_class.call(token:)

      expect(result).to be_ok
      expect(token.reload.revoked_at).to be_within(1.second).of(original)
    end
  end
end
