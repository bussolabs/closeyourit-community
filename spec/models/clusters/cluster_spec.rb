# frozen_string_literal: true

require "rails_helper"

RSpec.describe Clusters::Cluster do
  it "keeps names unique inside an organization" do
    cluster = create(:cluster)
    duplicate = build(:cluster, organization: cluster.organization, name: cluster.name)
    expect(duplicate).not_to be_valid
  end

  it "is revoked once revoked_at is set" do
    expect(build(:cluster, revoked_at: Time.current).revoked?).to be(true)
  end
end
