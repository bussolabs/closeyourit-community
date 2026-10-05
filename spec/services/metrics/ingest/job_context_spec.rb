# frozen_string_literal: true

require "rails_helper"

RSpec.describe Metrics::Ingest::JobContext do
  root = Rails.root.join("contracts/jobs/v1")
  JSON.parse(root.join("manifest.json").read).fetch("fixtures").each do |fixture|
    it "validates the canonical #{fixture.fetch('path')} boundary" do
      context = JSON.parse(root.join(fixture.fetch("path")).read)
      expect(described_class.valid?(context)).to eq(fixture.fetch("valid"))
    end
  end

  it "rejects excessive nesting without traversing arbitrary input" do
    expect(described_class.valid?({ "name" => Array.new(10_000, {}) })).to be(false)
  end
end
