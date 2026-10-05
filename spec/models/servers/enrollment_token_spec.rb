# frozen_string_literal: true

require "rails_helper"

RSpec.describe Servers::EnrollmentToken, type: :model do
  describe "validazioni" do
    it "è valido con organization, name, prefix e digest" do
      expect(build(:server_enrollment_token)).to be_valid
    end

    it "rifiuta un name duplicato nella stessa organization" do
      existing = create(:server_enrollment_token)
      dup = build(:server_enrollment_token, organization: existing.organization, name: existing.name)

      expect(dup).not_to be_valid
    end

    it "rifiuta un token_digest duplicato" do
      existing = create(:server_enrollment_token)
      dup = build(:server_enrollment_token, token_digest: existing.token_digest)

      expect(dup).not_to be_valid
    end
  end

  describe ".active / #revoked?" do
    it "esclude i token revocati" do
      active = create(:server_enrollment_token)
      revoked = create(:server_enrollment_token, :revoked, organization: active.organization)

      expect(described_class.active).to include(active)
      expect(described_class.active).not_to include(revoked)
      expect(revoked.revoked?).to be(true)
    end
  end

  # CYRA-469 — il codice sa quante macchine ci si sono registrate, e cancellarlo non se le porta via.
  describe "#hosts" do
    it "raccoglie gli host registrati con questo codice" do
      token = create(:server_enrollment_token)
      mine = create(:server_host, organization: token.organization, enrollment_token: token)
      other = create(:server_host, organization: token.organization)

      expect(token.hosts).to include(mine)
      expect(token.hosts).not_to include(other)
    end

    it "alla cancellazione stacca gli host (nullify), non li elimina" do
      token = create(:server_enrollment_token)
      host = create(:server_host, organization: token.organization, enrollment_token: token)

      expect { token.destroy }.not_to change(Servers::Host, :count)
      expect(host.reload.enrollment_token_id).to be_nil
    end
  end

  describe "#stale_usage?" do
    it "è true senza last_used_at, oltre soglia, false entro soglia" do
      token = build(:server_enrollment_token, last_used_at: nil)
      expect(token.stale_usage?).to be(true)

      token.last_used_at = 2.minutes.ago
      expect(token.stale_usage?).to be(true)

      token.last_used_at = 10.seconds.ago
      expect(token.stale_usage?).to be(false)
    end
  end
end
