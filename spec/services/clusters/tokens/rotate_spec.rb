# frozen_string_literal: true

require "rails_helper"

RSpec.describe Clusters::Tokens::Rotate do
  it "replaces the digest so the old token stops working" do
    cluster = Clusters::Tokens::Issue.call(organization: create(:organization), name: "lab").value[:cluster]
    old_digest = cluster.token_digest

    secret = described_class.call(cluster:).value[:secret]

    expect(cluster.reload.token_digest).to eq(Digest::SHA256.hexdigest(secret))
    expect(cluster.token_digest).not_to eq(old_digest)
    expect(cluster.revoked_at).to be_nil
  end
end
