# frozen_string_literal: true

require "rails_helper"

# CYAU-329 — the Tester's outcome a machine delivers: read only when it has the shape of the contract.
RSpec.describe Agents::Tester::Report do
  def block(**overrides)
    { "moment" => "delivery", "status" => "passed", "engine" => "codex", "commit" => "a" * 40,
      "summary" => "Two proofs run, both passed.",
      "results" => [ { "criterion_id" => "DOD-1", "kind" => "test", "status" => "passed", "evidence" => "12 examples, 0 failures" } ] }
      .merge(overrides.transform_keys(&:to_s))
  end

  it "reads a block that follows the contract" do
    report = described_class.parse(block)

    expect(report).to have_attributes(moment: "delivery", status: "passed", engine: "codex", commit: "a" * 40)
    expect(report.status_of("DOD-1")).to eq("passed")
    expect(report.status_of("DOD-9")).to be_nil
  end

  it "reads nothing from a delivery that carries no block" do
    expect(described_class.parse(nil)).to be_nil
    expect(described_class.parse("passed")).to be_nil
  end

  it "reads nothing from a block outside the contract" do
    expect(described_class.parse(block(status: "green"))).to be_nil
    expect(described_class.parse(block(commit: "abc"))).to be_nil
    expect(described_class.parse(block.except("results"))).to be_nil
    expect(described_class.parse(block(extra: true))).to be_nil
  end

  it "lists the criteria that passed" do
    report = described_class.parse(block(results: [
      { "criterion_id" => "DOD-1", "kind" => "test", "status" => "passed", "evidence" => "ok" },
      { "criterion_id" => "DOD-2", "kind" => "command", "status" => "failed", "evidence" => "exit 1" }
    ]))

    expect(report.passed_ids).to eq(%w[DOD-1])
  end
end
