# frozen_string_literal: true

require "rails_helper"

RSpec.describe Servers::EnrollmentTokens::Issue do
  let(:organization) { create(:organization) }

  it "emette un token con prefisso cyi_s_, persiste solo il digest e mostra il segreto una volta" do
    result = described_class.call(organization:, name: "fleet")

    expect(result).to be_ok
    secret = result.value[:secret]
    token = result.value[:token]
    expect(secret).to start_with(Servers::Constants::TOKEN_PREFIX)
    expect(token.token_digest).to eq(Digest::SHA256.hexdigest(secret))
    expect(token.token_prefix).to eq(secret[0, described_class::DISPLAY_PREFIX_LENGTH])
    expect(token.attributes.values).not_to include(secret)
  end

  it "fallisce con R422-SERVER-003 su nome duplicato" do
    described_class.call(organization:, name: "fleet")
    result = described_class.call(organization:, name: "fleet")

    expect(result).to be_err
    expect(result.error.code).to eq("R422-SERVER-003")
  end
end
