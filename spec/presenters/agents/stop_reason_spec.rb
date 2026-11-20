# frozen_string_literal: true

require "rails_helper"

# CYRA-1329 — on 2026-11-19 the queue held 74 pieces of work stopped with no reason on screen: whoever
# had to decide could not tell what to do without opening the database. Every stop says, in plain
# words, what stopped it and where.
RSpec.describe Agents::StopReason, type: :model do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, organization:, project:) }
  let(:workflow) { create(:agent_workflow, ticket:, triage_requested_at: 2.days.ago, triage_started_at: 1.day.ago) }

  def note(stalled_phase: nil) = described_class.for(workflow: workflow, stalled_phase: stalled_phase)

  def block!(kind:, reason:, phase: "planner")
    workflow.update!(blocked_at: Time.current, blocked_phase: phase, blocked_kind: kind, blocked_reason: reason)
  end

  it "says nothing about a piece of work that is not stopped" do
    expect(note).to be_nil
  end

  # AC-1 — the budget ran out: the kind and the phase are the reason, and the audit line behind it
  # ("attempt_limit: planner failed 2 times") is not a sentence anyone should have to read.
  it "names the exhausted attempts and the phase they ran out on" do
    block!(kind: "attempt_limit", reason: "attempt_limit: planner failed 2 times")

    expect(note).to have_attributes(kind: "attempt_limit", phase: "planner")
    expect(note.reason).to include("Planning").and include("attempts")
  end

  it "carries the agent's own words, without the audit prefix" do
    block!(kind: "agent_blocked", reason: "agent_blocked: the invoice totals are unclear")

    expect(note).to have_attributes(kind: "agent_blocked", phase: "planner")
    expect(note.reason).to include("the invoice totals are unclear")
    expect(note.reason).not_to include("agent_blocked:")
  end

  it "tells the proposal check apart from the release check" do
    block!(kind: "candidate_check", reason: "candidate_check: checks_failing, the permission spec is red")
    expect(note.reason).to include("proposal check").and include("the permission spec is red")

    workflow.update!(blocked_kind: "release_probe", blocked_reason: "release_probe: release_run_failed")
    expect(note.reason).to include("release check").and include("release_run_failed")
  end

  it "names the person who held the release" do
    block!(kind: "held_by_person", reason: "held_by_person: Ada Lovelace", phase: "closer_production")

    expect(note).to have_attributes(kind: "held_by_person", phase: "closer_production")
    expect(note.reason).to include("Ada Lovelace")
  end

  it "says a person has to give the go-ahead for production" do
    block!(kind: "production_approval", reason: "production_approval", phase: "closer_production")

    expect(note.reason).to include("go-ahead")
  end

  it "says only a person releases a safety stop" do
    block!(kind: "safety_stop", reason: "safety_stop: tried to push to main")

    expect(note.reason).to include("tried to push to main").and include("safety")
    expect(note.reason).not_to include("safety_stop:")
  end

  # The database constraint keeps a block without a reason from existing, but a reason made of the
  # prefix alone would leave an empty quote on screen: there the sentence says so.
  it "says the agent wrote no reason when the words are missing" do
    block!(kind: "agent_blocked", reason: "agent_blocked:")

    expect(note.reason).to include("wrote no reason")
  end

  # AC-6 / CYRA-267 — rejected under the attempts cap: no blocked_at to read, and the queue stops
  # proposing the phase. Stopped all the same, and until now the only row with nothing to show.
  it "explains a phase rejected in review that nobody is retrying" do
    stopped = note(stalled_phase: "triage")

    expect(stopped).to have_attributes(kind: "stalled_review", phase: "triage")
    expect(stopped.reason).to include("Triage")
  end

  it "prefers the written block to the stalled phase" do
    block!(kind: "attempt_limit", reason: "attempt_limit: planner failed 2 times")

    expect(note(stalled_phase: "triage")).to have_attributes(kind: "attempt_limit", phase: "planner")
  end

  # The sentence is read in the language of whoever is deciding: a kind missing from one of the two
  # locales would print the i18n placeholder right where the decision is made.
  it "has the sentence of every kind in both languages" do
    (Agents::Workflows::Block::KINDS + [ described_class::STALLED_KIND ]).each do |kind|
      %i[it en].each do |locale|
        expect(I18n.t("agents.stop_reason.#{kind}", locale:, default: nil)).to be_present, "#{kind} missing in #{locale}"
      end
    end
  end

  it "says nothing about a cancelled or completed piece of work" do
    workflow.update!(cancelled_at: Time.current, cancellation_reason: "no longer needed")

    expect(note(stalled_phase: "triage")).to be_nil
  end

  # CYRA-1330 — the review was never produced, time after time. Nothing was judged, so the sentence
  # of the attempts cap would be false here: it names the review and counts rejections that are zero.
  it "tells a repeated technical fault from exhausted attempts" do
    block!(kind: "review_fault", reason: "review_fault: planner not judged 3 times")

    expect(note).to have_attributes(kind: "review_fault", phase: "planner")
    expect(note.reason).to include("Planning")
    expect(note.reason).not_to include("review_fault:")
  end
end
