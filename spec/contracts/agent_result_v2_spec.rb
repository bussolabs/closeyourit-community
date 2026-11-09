# frozen_string_literal: true

require "rails_helper"
require "digest"

RSpec.describe "Agent result contract v2" do
  let(:contract) { Rails.root.join("contracts/agent-result/v2") }

  def contract_schema
    @contract_schema ||= JSON.parse(contract.join("schema.json").read)
  end

  it "protegge tutti i file del bundle con i checksum" do
    lock = JSON.parse(Rails.root.join("contracts/agent-result/LOCK.v2.json").read)
    expect(Digest::SHA256.hexdigest(contract.join("SHA256SUMS").read)).to eq(lock.fetch("sha256sums"))
    expected = contract.join("SHA256SUMS").read.each_line.to_h do |line|
      digest, relative = line.strip.split("  ./", 2)
      [ relative, digest ]
    end
    actual = contract.glob("**/*").select(&:file?).reject { |path| path.basename.to_s == "SHA256SUMS" }
                     .to_h { |path| [ path.relative_path_from(contract).to_s, Digest::SHA256.file(path).hexdigest ] }

    expect(actual).to eq(expected)
  end

  it "accetta e rifiuta le fixture del manifest" do
    manifest = JSON.parse(contract.join("manifest.json").read)

    manifest.fetch("fixtures").each do |fixture|
      document = JSON.parse(contract.join(fixture.fetch("path")).read)
      errors = contract_errors(contract_schema, fixture.fetch("definition"), document)

      expect(errors.empty?).to eq(fixture.fetch("valid")), fixture.fetch("path")
    end
  end

  it "tiene distinti v1 e v2 tramite contract_version" do
    v2 = JSON.parse(contract.join("fixtures/valid/planner.json").read)
    legacy = v2.except("contract_version", "plan").merge("technical_analysis" => "testo legacy")

    expect(contract_errors(contract_schema, "planner_result", v2)).to be_empty
    expect(contract_errors(contract_schema, "planner_result", legacy)).not_to be_empty
  end

  # CYRA-1152 — an epic's plan may carry its proposed children: optional, at least two, within the cap,
  # each with scenarios and the children it waits for. The planner still has three outcomes. The block
  # is not in the canonical contract yet: the vendored copy stays the pinned one, and the server checks
  # `children` on its own shape and the rest of the plan against the vendored schema.
  describe "split proposal" do
    let(:split) { JSON.parse(Rails.root.join("spec/fixtures/agents/planner_split.json").read) }
    let(:children_validator) { Agents::Attempts::DeliveryContract::PLAN_CHILDREN_VALIDATOR }

    def errors_with(&change)
      document = split.deep_dup.tap(&change)
      children = document["plan"].delete("children")
      contract_errors(contract_schema, "planner_result", document) +
        (children.nil? ? [] : children_validator.validate(children).to_a)
    end

    it "accepts a plan with children and a plan without" do
      expect(errors_with { |document| document }).to be_empty
      expect(errors_with { |document| document["plan"].delete("children") }).to be_empty
    end

    it "does not carry children in the vendored contract, which stays the pinned one" do
      expect(contract_errors(contract_schema, "planner_result", split)).not_to be_empty
    end

    it "refuses a single child, a child without scenarios and a prerequisite that is not a child id" do
      expect(errors_with { |document| document["plan"]["children"] = document["plan"]["children"].first(1) }).not_to be_empty
      expect(errors_with { |document| document["plan"]["children"].first["scenarios"] = [] }).not_to be_empty
      expect(errors_with { |document| document["plan"]["children"].last["dependencies"] = [ "WI-1" ] }).not_to be_empty
    end

    it "refuses more children than the cap, and a child with a field the shape does not know" do
      over = (1..(Agents::PlanSplit::MAX_CHILDREN + 1)).map { |index| split.dig("plan", "children", 0).merge("id" => "CH-#{index}") }

      expect(errors_with { |document| document["plan"]["children"] = over }).not_to be_empty
      expect(errors_with { |document| document["plan"]["children"].first["owner"] = "someone" }).not_to be_empty
    end

    it "refuses a child description longer than a ticket's, and accepts one right at the limit" do
      limit = Ticketing::Constants::DESCRIPTION_MAX_CHARS

      expect(errors_with { |document| document["plan"]["children"].first["description"] = "a" * limit }).to be_empty
      expect(errors_with { |document| document["plan"]["children"].first["description"] = "a" * (limit + 1) }).not_to be_empty
    end

    it "keeps the planner to its three outcomes" do
      expect(contract_schema.dig("$defs", "planner_result", "properties", "state", "enum"))
        .to eq(%w[submitted-for-approval blocked already-done])
    end
  end

  # CYRA-872 — costo e modello viaggiano accanto al result: la busta del contratto li ammette già
  # (additionalProperties), e il giorno che smettesse di farlo la consegna dei costi si romperebbe qui.
  it "ammette costo e modello dell'host fuori dal result, in v1 e in v2" do
    %w[v1 v2].each do |version|
      root = Rails.root.join("contracts/agent-result", version)
      envelope = JSON.parse(root.join("fixtures/valid/delivery_envelope.json").read)
      schema = JSON.parse(root.join("schema.json").read)

      expect(contract_errors(schema, "delivery_envelope", envelope.merge("cost_usd" => 0.42, "model" => "claude-opus-5-5")))
        .to be_empty, version
    end
  end
end
