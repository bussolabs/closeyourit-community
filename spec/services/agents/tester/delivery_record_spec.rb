# frozen_string_literal: true

require "rails_helper"

# CYAU-329 — the ticket history says what the Tester measured on a delivery, whoever decides afterwards.
RSpec.describe Agents::Tester::DeliveryRecord do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, key: "CYAU") }
  let(:ticket) { create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:commit) { "a" * 40 }

  def block(**overrides)
    { "moment" => "delivery", "status" => "failed", "engine" => "codex", "commit" => commit, "summary" => "One proof failed.",
      "results" => [
        { "criterion_id" => "DOD-1", "kind" => "test", "status" => "passed", "evidence" => "exit 0" },
        { "criterion_id" => "DOD-2", "kind" => "command", "status" => "failed", "evidence" => "exit 1" },
        { "criterion_id" => "DOD-3", "kind" => "command", "status" => "not_run", "evidence" => "no command" }
      ] }.merge(overrides.transform_keys(&:to_s))
  end

  def record(tester) = described_class.call(workflow:, block: tester)

  def events = Ticketing::Event.where(ticket:, action: "delivery_tester_ran")

  it "writes nothing while the Tester is off" do
    record(block)

    expect(events).to be_empty
  end

  context "with the Tester in dry run" do
    before { project.update!(tester: "dry_run") }

    it "says which proofs passed, failed and did not run, and with which engine" do
      record(block)

      expect(events.sole.data).to include("engine" => "codex", "commit" => commit, "mode" => "dry_run",
                                          "passed" => %w[DOD-1], "failed" => %w[DOD-2], "not_run" => %w[DOD-3])
    end

    it "writes nothing without an outcome, or for one that is not a delivery" do
      record(nil)
      record(block(moment: "staging"))

      expect(events).to be_empty
    end
  end
end
