# frozen_string_literal: true

require "rails_helper"

# CYRA-1292 — "no red check" proves nothing until the repository says which checks count.
RSpec.describe Agents::Candidates::RequiredChecks do
  def pinned(*names)
    { "version" => 2, "checks" => [ { "stage" => "lint", "run" => "bin/rubocop" } ],
      "remote" => { "provider" => "github", "required_checks" => names } }.to_yaml
  end

  def run(name, conclusion = "SUCCESS") = { "__typename" => "CheckRun", "name" => name, "conclusion" => conclusion }
  def status(context, state = "SUCCESS") = { "__typename" => "StatusContext", "context" => context, "state" => state }

  def check(config, *checks) = described_class.call(config:, checks:)

  it "clears a pull request that passed every declared check" do
    verdict = check(pinned("ci / ci-gate", "migration-versions"), run("ci / ci-gate"), status("migration-versions"))

    expect(verdict).to have_attributes(review?: false, declared: [ "ci / ci-gate", "migration-versions" ], missing: [])
  end

  it "asks for a person when a declared check is not among the green ones" do
    verdict = check(pinned("ci / ci-gate", "migration-versions"), run("ci / ci-gate"))

    expect(verdict.reasons).to eq(%w[required_checks_missing])
    expect(verdict.missing).to eq(%w[migration-versions])
  end

  it "does not count a declared check that was skipped" do
    verdict = check(pinned("ci / ci-gate"), run("ci / ci-gate", "SKIPPED"))

    expect(verdict.missing).to eq([ "ci / ci-gate" ])
  end

  it "asks for a person when the repository has no file" do
    expect(check(nil, run("ci")).reasons).to eq(%w[required_checks_undeclared])
  end

  it "asks for a person when the file is an older version" do
    old = { "version" => 1, "checks" => [ { "stage" => "lint", "run" => "x" } ] }.to_yaml

    expect(check(old, run("ci")).reasons).to eq(%w[required_checks_undeclared])
  end

  it "asks for a person when the list of required checks is empty" do
    expect(check(pinned, run("ci")).reasons).to eq(%w[required_checks_undeclared])
  end

  it "treats a file that is not valid YAML as declaring nothing" do
    expect(check("version: [2", run("ci")).reasons).to eq(%w[required_checks_undeclared])
  end

  it "does not build objects from the file" do
    expect(check("--- !ruby/object:OpenStruct\nversion: 2\n", run("ci")).reasons).to eq(%w[required_checks_undeclared])
  end

  it "says nothing is declared when the file could not be read" do
    expect(described_class.unreadable.reasons).to eq(%w[required_checks_undeclared])
  end
end
