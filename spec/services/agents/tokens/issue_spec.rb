# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Tokens::Issue, type: :service do
  let(:organization) { create(:organization) }

  it "emette un token cyi_a_ mostrando il segreto una volta e salvando solo il digest" do
    result = described_class.call(organization:, name: "automator")
    expect(result).to be_ok
    secret = result.value[:secret]
    token = result.value[:token]

    expect(secret).to start_with("cyi_a_")
    expect(token.token_prefix).to eq(secret[0, 14])
    expect(token.token_digest).to eq(Digest::SHA256.hexdigest(secret))
    expect(Agents::Token.column_names).not_to include("secret")
  end

  it "ritorna err R422-AGENT-003 su nome duplicato per org" do
    described_class.call(organization:, name: "dup")
    result = described_class.call(organization:, name: "dup")
    expect(result).to be_err
    expect(result.error.code).to eq("R422-AGENT-003")
  end
end
