# frozen_string_literal: true

require "rails_helper"

# CYAU-235 — every decision the supporter takes alone waits in "To review" until a person marks it seen.
RSpec.describe Agents::SupporterDecision do
  let(:workflow) { create(:agent_workflow) }
  let(:person) { create(:account) }

  def decision(**attributes)
    described_class.create!({ organization: workflow.organization, workflow: workflow, target_type: "question",
                              target_id: SecureRandom.uuid, target_digest: "sha256:abc", outcome: "answered",
                              engine: "codex", risk_score: 3 }.merge(attributes))
  end

  it "lists applied decisions not yet seen as to review" do
    pending_one = decision
    decision(outcome: "escalated")
    decision.mark_seen!(by: person)

    expect(described_class.to_review).to contain_exactly(pending_one)
  end

  it "records who saw it and when" do
    record = decision
    record.mark_seen!(by: person)
    expect(record.reload.seen_by).to eq(person)
    expect(record.seen_at).to be_present
  end

  it "refuses a second decision on the same target version" do
    target = SecureRandom.uuid
    decision(target_id: target)
    expect { decision(target_id: target) }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "keeps the risk score between 1 and 10 and the outcome among the known ones" do
    expect { decision(risk_score: 11) }.to raise_error(ActiveRecord::RecordInvalid)
    expect { decision(outcome: "guessed") }.to raise_error(ActiveRecord::RecordInvalid)
  end
end
