# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Open Dashboard contract v1" do
  let(:root) { Rails.root.join("contracts/open-dashboard/v1") }
  let(:schema) { JSON.parse(root.join("schema.json").read) }

  it "applies the declared validity to every fixture" do
    JSON.parse(root.join("manifest.json").read).fetch("fixtures").each do |fixture|
      document = JSON.parse(root.join(fixture.fetch("path")).read)
      errors = contract_errors(schema, fixture.fetch("definition"), document)

      expect(errors.empty?).to eq(fixture.fetch("valid")), fixture.fetch("path")
    end
  end
end
