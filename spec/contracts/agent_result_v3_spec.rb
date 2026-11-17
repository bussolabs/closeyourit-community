# frozen_string_literal: true

require "rails_helper"
require "digest"

RSpec.describe "Agent result contract v3" do
  let(:contract) { Rails.root.join("contracts/agent-result/v3") }

  def contract_schema
    @contract_schema ||= JSON.parse(contract.join("schema.json").read)
  end

  it "protects every file of the bundle with its checksum" do
    lock = JSON.parse(Rails.root.join("contracts/agent-result/LOCK.v3.json").read)
    expect(Digest::SHA256.hexdigest(contract.join("SHA256SUMS").read)).to eq(lock.fetch("sha256sums"))
    expected = contract.join("SHA256SUMS").read.each_line.to_h do |line|
      digest, relative = line.strip.split("  ./", 2)
      [ relative, digest ]
    end
    actual = contract.glob("**/*").select(&:file?).reject { |path| path.basename.to_s == "SHA256SUMS" }
                     .to_h { |path| [ path.relative_path_from(contract).to_s, Digest::SHA256.file(path).hexdigest ] }

    expect(actual).to eq(expected)
  end

  it "accepts and rejects the fixtures of the manifest" do
    manifest = JSON.parse(contract.join("manifest.json").read)

    manifest.fetch("fixtures").each do |fixture|
      document = JSON.parse(contract.join(fixture.fetch("path")).read)
      errors = contract_errors(contract_schema, fixture.fetch("definition"), document)

      expect(errors.empty?).to eq(fixture.fetch("valid")), fixture.fetch("path")
    end
  end

  it "takes the plan's proof of each ticket item, never a list of its own (CYRA-1316)" do
    v3 = JSON.parse(contract.join("fixtures/valid/planner.json").read)
    own_lists = v3.except("item_verifications", "proposed_items")
                  .merge("scenarios" => [], "definition_of_done" => [ { "id" => "DOD-1", "text" => "Done" } ])

    expect(contract_errors(contract_schema, "planner_result", v3)).to be_empty
    expect(contract_errors(contract_schema, "planner_result", own_lists)).not_to be_empty
  end
end
