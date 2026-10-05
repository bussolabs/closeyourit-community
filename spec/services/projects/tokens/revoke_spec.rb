require "rails_helper"

RSpec.describe Projects::Tokens::Revoke, type: :service do
  let(:token) { create(:project_token) }

  it "imposta revoked_at e ritorna Result.ok" do
    result = described_class.call(token:)

    expect(result).to be_ok
    expect(token.reload.revoked_at).to be_present
    expect(token).to be_revoked
  end

  it "esclude il token dallo scope active dopo la revoca" do
    described_class.call(token:)
    expect(Projects::Token.active).not_to include(token.reload)
  end

  it "è idempotente: ri-revocare non cambia revoked_at" do
    described_class.call(token:)
    first_revoked_at = token.reload.revoked_at

    travel_to(1.hour.from_now) do
      described_class.call(token:)
      expect(token.reload.revoked_at).to eq(first_revoked_at)
    end
  end
end
