# frozen_string_literal: true

require "rails_helper"

# CYAU-329 — the ticket history says what the Tester saw on staging before the production tag.
RSpec.describe Agents::Tester::ReleaseRecord do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, key: "CYAU") }
  let(:ticket) { create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:commit) { "a" * 40 }

  def plan(kinds)
    done = kinds.each_with_index.map do |kind, index|
      { "id" => "DOD-#{index + 1}", "text" => "The button reads Save", "verification" => { "kind" => kind, "how" => "Open the page" } }
    end
    Agents::Plan.create!(
      workflow:, attempt: create(:agent_attempt, organization:, workflow:, phase: "planner"), contract_version: 2,
      technical_analysis: "Change one label.", scenarios: [], notes: [], definition_of_done: done,
      content: { "summary" => "Change one label.", "work_items" => [] }, ticket_snapshot_digest: "snapshot",
      approved_at: Time.current
    )
  end

  def block(**overrides)
    { "moment" => "staging", "status" => "passed", "engine" => "claude", "commit" => commit, "summary" => "Seen on staging.",
      "results" => [ { "criterion_id" => "DOD-1", "kind" => "browser", "status" => "passed", "evidence" => "The button reads Save",
                       "attachment" => "tester-DOD-1.png" } ] }.merge(overrides.transform_keys(&:to_s))
  end

  def record(tester) = described_class.call(workflow:, block: tester, commit:)
  def events = Ticketing::Event.where(ticket:).where("action LIKE 'delivery_tester_release_%'")

  before { plan(%w[browser test]) }

  it "writes nothing while the Tester is off" do
    record(block)

    expect(events).to be_empty
  end

  context "with the Tester on" do
    before { project.update!(tester: "on") }

    it "says the browser proofs passed on staging" do
      record(block)

      expect(events.sole).to have_attributes(action: "delivery_tester_release_passed")
      expect(events.sole.data).to include("criteria" => %w[DOD-1], "engine" => "claude")
    end

    it "says the release went out without the Tester's proof" do
      record(nil)

      expect(events.sole).to have_attributes(action: "delivery_tester_release_missing")
      expect(events.sole.data).to include("criteria" => %w[DOD-1])
    end

    it "does not take a proof made on another commit, at delivery, or with a failed criterion" do
      [ block(commit: "b" * 40), block(moment: "delivery"),
        block(results: [ { "criterion_id" => "DOD-1", "kind" => "browser", "status" => "failed", "evidence" => "No button" } ]) ].each do |tester|
        record(tester)
      end

      expect(events.pluck(:action)).to eq(%w[delivery_tester_release_missing] * 3)
    end

    it "writes nothing when a person gave the go-ahead: they did the proof" do
      workflow.update!(closer_production_approved_at: Time.current)

      record(nil)

      expect(events).to be_empty
    end

    it "writes nothing for a plan with no browser proof" do
      workflow.plans.destroy_all
      plan(%w[test])

      record(nil)

      expect(events).to be_empty
    end
  end

  it "records in a dry run too" do
    project.update!(tester: "dry_run")

    record(block)

    expect(events.sole).to have_attributes(action: "delivery_tester_release_passed")
  end
end
