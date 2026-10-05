# frozen_string_literal: true

require "rails_helper"

RSpec.describe OrganizationSerializer do
  # CYRA-521 — il campo resta nel contratto per un giro, ma non ha più niente da dire: è sempre null
  # finché i client `cyi` installati non smettono di leggerlo.
  it "espone default_space sempre nullo (deprecato)" do
    org = build(:organization)
    hash = described_class.new(org).serializable_hash
    expect(hash["default_space"]).to be_nil
  end
end
