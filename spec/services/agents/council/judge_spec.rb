# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Council::Judge do
  def proposal(ref: "claude-1", proposer: "claude", **extra)
    { "ref" => ref, "proposer" => proposer, "title" => "Index tickets.status_id", "problem" => "Slow list",
      "solution" => "Add an index", "kind" => "code", "risk" => "low", "engine" => "codex",
      "model" => "gpt-6-astra" }.merge(extra.transform_keys(&:to_s))
  end

  def vote(ref: "claude-1", critic: "codex", choice: "approve", risk: "low")
    { "ref" => ref, "critic" => critic, "vote" => choice, "risk" => risk, "reason" => "fine" }
  end

  def judge(proposals, critiques) = described_class.call(proposals:, critiques:)

  it "passes a proposal the other engine approves" do
    verdict = judge([ proposal ], [ vote ]).first
    expect(verdict.passed).to be(true)
    expect(verdict.reasons).to be_empty
  end

  it "rejects a proposal the other engine rejects" do
    expect(judge([ proposal ], [ vote(choice: "reject") ]).first.reasons).to eq([ "rejected" ])
  end

  it "rejects a proposal nobody voted on" do
    expect(judge([ proposal ], []).first.reasons).to eq([ "no_vote" ])
  end

  it "ignores a vote the proposer cast on its own proposal" do
    expect(judge([ proposal ], [ vote(critic: "claude") ]).first.reasons).to eq([ "no_vote" ])
  end

  it "blocks a serious risk flagged by the critic" do
    expect(judge([ proposal ], [ vote(risk: "serious") ]).first.reasons).to eq([ "serious_risk" ])
  end

  it "blocks a serious risk flagged by the proposer" do
    expect(judge([ proposal(risk: "serious") ], [ vote ]).first.reasons).to eq([ "serious_risk" ])
  end

  it "marks a proposal without title or problem as invalid" do
    expect(judge([ proposal(title: " ") ], [ vote ]).first.reasons).to eq([ "invalid" ])
  end

  it "drops an unknown engine and a model outside the engine's list" do
    verdict = judge([ proposal(engine: "gemini", model: "gpt-6-astra") ], [ vote ]).first
    expect(verdict.proposal.values_at("engine", "model")).to eq([ nil, nil ])
    expect(judge([ proposal(engine: "claude", model: "gpt-6-astra") ], [ vote ]).first.proposal["model"]).to be_nil
  end

  it "keeps at most three proposals per engine" do
    proposals = (1..4).map { |i| proposal(ref: "claude-#{i}") }
    expect(judge(proposals, []).size).to eq(3)
  end

  it "ignores a proposal from an unknown proposer" do
    expect(judge([ proposal(proposer: "kimi") ], [])).to be_empty
  end
end
