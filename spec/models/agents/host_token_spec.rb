# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::HostToken, type: :model do
  it "richiede digest e prefisso, con digest globalmente unico" do
    existing = create(:agent_host_token)
    missing = build(:agent_host_token, token_digest: "", token_prefix: "")
    duplicate = build(:agent_host_token, token_digest: existing.token_digest)

    expect(missing).to be_invalid
    expect(missing.errors.attribute_names).to include(:token_digest, :token_prefix)
    expect(duplicate).to be_invalid
  end

  it "espone solo credenziali attive e rileva l'uso stantio" do
    live = create(:agent_host_token, last_used_at: nil)
    revoked = create(:agent_host_token, :revoked)

    expect(described_class.active).to include(live)
    expect(described_class.active).not_to include(revoked)
    expect(live.stale_usage?).to be(true)
    expect(revoked.revoked?).to be(true)
  end
end
