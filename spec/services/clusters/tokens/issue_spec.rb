# frozen_string_literal: true

require "rails_helper"

RSpec.describe Clusters::Tokens::Issue do
  let(:organization) { create(:organization) }

  it "creates a pending cluster and shows the secret once" do
    result = described_class.call(organization:, name: "production-eu")

    expect(result).to be_ok
    secret = result.value[:secret]
    cluster = result.value[:cluster]
    expect(secret).to start_with("cyi_k_")
    expect(cluster).to be_status_pending
    expect(cluster.token_digest).to eq(Digest::SHA256.hexdigest(secret))
    expect(cluster.token_prefix).to eq(secret[0, 14])
    expect(cluster.attributes.values).not_to include(secret)
  end

  it "refuses a duplicate name" do
    described_class.call(organization:, name: "production-eu")
    result = described_class.call(organization:, name: "production-eu")
    expect(result).not_to be_ok
    expect(result.error.code).to eq("R422-CLUSTER-002")
  end
end
