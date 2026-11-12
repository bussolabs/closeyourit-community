# frozen_string_literal: true

require "rails_helper"

# CYRA-1294 — the trial release counts only when its deploy and its smoke check both finished well.
RSpec.describe Agents::Staging::DeployRun do
  let(:client) { instance_double(Github::Client) }

  def job(name, conclusion) = { "name" => name, "conclusion" => conclusion }

  def runs(*list)
    allow(client).to receive(:workflow_runs).with(7, "acme/api", "c" * 40)
      .and_return(list.each_with_index.map { |(conclusion, _), index| { "id" => index, "conclusion" => conclusion } })
    list.each_with_index do |(_, jobs), index|
      allow(client).to receive(:workflow_run_jobs).with(7, "acme/api", index).and_return(jobs)
    end
  end

  def outcome = described_class.outcome(client:, installation: 7, repository: "acme/api", commit: "c" * 40)

  it "is released when the deploy and the smoke check both succeeded" do
    runs([ "success", [ job("ci / deploy-staging", "success"), job("ci / smoke-staging", "success") ] ])

    expect(outcome).to eq(:released)
  end

  it "is pending while no run holds the two jobs" do
    runs([ "success", [ job("ci / lint", "success") ] ])

    expect(outcome).to eq(:pending)
  end

  it "is pending while the jobs are still running" do
    runs([ nil, [ job("ci / deploy-staging", "success"), job("ci / smoke-staging", nil) ] ])

    expect(outcome).to eq(:pending)
  end

  it "is pending when the two jobs were skipped in a green run" do
    runs([ "success", [ job("ci / deploy-staging", "skipped"), job("ci / smoke-staging", "skipped") ] ])

    expect(outcome).to eq(:pending)
  end

  it "is failed when the smoke check failed" do
    runs([ "failure", [ job("ci / deploy-staging", "success"), job("ci / smoke-staging", "failure") ] ])

    expect(outcome).to eq(:failed)
  end

  it "is released when a later run went fine after a cancelled one" do
    runs([ "cancelled", [ job("ci / deploy-staging", "cancelled"), job("ci / smoke-staging", "skipped") ] ],
         [ "success", [ job("ci / deploy-staging", "success"), job("ci / smoke-staging", "success") ] ])

    expect(outcome).to eq(:released)
  end

  it "is pending when the commit has no run at all" do
    runs

    expect(outcome).to eq(:pending)
  end
end
