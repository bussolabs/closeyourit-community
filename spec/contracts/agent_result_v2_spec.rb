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
