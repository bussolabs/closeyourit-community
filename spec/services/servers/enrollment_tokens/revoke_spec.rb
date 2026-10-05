# frozen_string_literal: true

require "rails_helper"

RSpec.describe Servers::EnrollmentTokens::Revoke do
  it "revoca il token e ri-revocare è idempotente" do
    token = create(:server_enrollment_token)

    expect(described_class.call(token:)).to be_ok
    first_revoked_at = token.reload.revoked_at
    expect(first_revoked_at).to be_present

    expect(described_class.call(token:)).to be_ok
    expect(token.reload.revoked_at).to eq(first_revoked_at)
  end
end
