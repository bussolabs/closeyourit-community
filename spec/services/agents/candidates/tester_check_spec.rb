# frozen_string_literal: true

require "rails_helper"

# CYAU-329 — a delivery whose plan names proofs to run moves on by itself only when the Tester ran them all,
# on the delivered commit, with an engine other than the one that wrote the work.
RSpec.describe Agents::Candidates::TesterCheck do
  let(:commit) { "a" * 40 }

  def criterion(id, kind) = { "id" => id, "text" => "done", "verification" => { "kind" => kind, "how" => "run it" } }
  def result(id, status, kind: "test") = { "criterion_id" => id, "kind" => kind, "status" => status, "evidence" => "seen" }

  def report(**overrides)
    Agents::Tester::Report.parse(
      { "moment" => "delivery", "status" => "passed", "engine" => "codex", "commit" => commit, "summary" => "All passed.",
        "results" => [ result("DOD-1", "passed"), result("DOD-2", "passed", kind: "command") ] }
        .merge(overrides.transform_keys(&:to_s))
    )
  end

  def check(report:, criteria: [ criterion("DOD-1", "test"), criterion("DOD-2", "command") ], writer: "claude", head: commit)
    described_class.call(report:, criteria:, commit: head, writer:)
  end

  it "owes nothing when the plan names no proof to run" do
    verdict = check(report: nil, criteria: [ criterion("DOD-1", "browser"), criterion("DOD-2", "manual"), { "id" => "DOD-3" } ])

    expect(verdict).to have_attributes(owed?: false, review?: false)
  end

  it "clears a delivery whose proofs all passed" do
    expect(check(report: report)).to have_attributes(owed?: true, review?: false, reasons: [])
  end

  it "asks for a person when the delivery carries no outcome" do
    expect(check(report: nil).reasons).to eq(%w[tester_absent])
  end

  it "asks for a person when the outcome belongs to the staging moment" do
    expect(check(report: report(moment: "staging")).reasons).to eq(%w[tester_absent])
  end

  it "asks for a person when a proof failed" do
    verdict = check(report: report(status: "failed", results: [ result("DOD-1", "passed"), result("DOD-2", "failed") ]))

    expect(verdict.reasons).to eq(%w[tester_failed])
    expect(verdict.failed).to eq(%w[DOD-2])
  end

  it "asks for a person when a proof of the plan was not run or is not in the outcome" do
    verdict = check(report: report(results: [ result("DOD-1", "not_run") ]))

    expect(verdict.reasons).to eq(%w[tester_incomplete])
    expect(verdict.missing).to eq(%w[DOD-1 DOD-2])
  end

  it "asks for a person when the Tester could not run" do
    expect(check(report: report(status: "unavailable", results: [])).reasons).to eq(%w[tester_incomplete])
  end

  it "asks for a person when the engine that tested also wrote the work" do
    expect(check(report: report, writer: "codex").reasons).to eq(%w[tester_same_engine])
  end

  it "asks for a person when the proofs ran on another commit" do
    expect(check(report: report, head: "b" * 40).reasons).to eq(%w[tester_stale])
    expect(check(report: report, head: nil).reasons).to eq(%w[tester_stale])
  end

  it "does not trust an overall pass that hides a failed proof" do
    verdict = check(report: report(results: [ result("DOD-1", "passed"), result("DOD-2", "failed") ]))

    expect(verdict.reasons).to eq(%w[tester_failed])
  end
end
