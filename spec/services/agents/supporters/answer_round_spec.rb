# frozen_string_literal: true

require "rails_helper"

# CYAU-235 — the supporter proposes; the server decides. It answers a round only when every open question
# passes: risk 1-6 after the server's own raises, no reserved topic, and enough confidence for its sources.
RSpec.describe Agents::Supporters::AnswerRound do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, supporter_enabled: true) }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true, title: "Add clamp(n, min, max)") }
  let(:workflow) { ticket.agent_workflow }
  let(:service_account) do
    create(:account, :service).tap { |a| create(:membership, account: a, organization:, role: :member) }
  end
  let(:host) { create(:agent_host, organization:, service_account:) }
  let(:round) do
    create(:agent_clarification, workflow:, questions: [
      { "body" => "Min greater than max: swap or throw?",
        "options" => [ { "label" => "Swap them" }, { "label" => "Throw an error", "recommended" => true } ] },
      "What should the error message say?"
    ])
  end
  let(:questions) { round.questions.order(:position).to_a }
  let(:digest) { Agents::Supporters::NextRound.digest(round, questions) }

  def answer(question, **overrides)
    { "question_id" => question.id, "risk_score" => 2, "confidence" => "high", "source_status" => "written",
      "sources" => [ "README.md" ], "rationale" => "The README says inputs are trusted.",
      "reasons_against" => "Swapping hides a caller bug.", "assumptions" => "Callers pass numbers.",
      "undo" => "Change the answer on the ticket." }.merge(overrides.transform_keys(&:to_s))
  end

  def call(answers, digest: self.digest)
    described_class.call(host:, round_id: round.id, payload: { "digest" => digest, "answers" => answers })
  end

  it "answers every question, records the decisions and puts the work back in triage" do
    result = call([ answer(questions[0], choice: 2), answer(questions[1], text: "min must not exceed max") ])

    expect(result).to be_ok
    expect(result.value[:outcome]).to eq("answered")
    expect(questions.map { |q| q.reload.answers.first&.body }).to eq([ "Throw an error", "min must not exceed max" ])
    expect(questions.first.answers.first).to have_attributes(origin: "agent", choice_index: 2)
    expect(round.reload.answered_at).to be_present
    expect(Agents::SupporterDecision.to_review.where(outcome: "answered").count).to eq(2)
  end

  it "hands the whole round to a person when one question is above 6" do
    result = call([ answer(questions[0], choice: 2), answer(questions[1], text: "x", risk_score: 7) ])

    expect(result.value[:outcome]).to eq("escalated")
    expect(questions.map { |q| q.reload.answers.count }).to eq([ 0, 0 ])
    expect(round.reload.answered_at).to be_nil
    expect(Agents::SupporterDecision.where(outcome: "escalated").count).to eq(2)
  end

  it "never decides alone on a reserved topic, whatever score it proposes" do
    create(:agent_automator_setting, organization:, supporter_reserved_topics: "clamp")

    result = call([ answer(questions[0], choice: 2), answer(questions[1], text: "x") ])

    expect(result.value[:outcome]).to eq("escalated")
    expect(result.value[:questions].first[:risk_score]).to eq(10)
  end

  it "needs high confidence to answer without a written source" do
    weak = answer(questions[1], text: "x", source_status: "no_written_source", confidence: "medium")
    expect(call([ answer(questions[0], choice: 2), weak ]).value[:outcome]).to eq("escalated")
  end

  it "accepts an answer without a written source when it is sure" do
    sure = answer(questions[1], text: "x", source_status: "no_written_source", confidence: "high")
    expect(call([ answer(questions[0], choice: 2), sure ]).value[:outcome]).to eq("answered")
  end

  it "treats a missing or unreadable score as the highest risk" do
    expect(call([ answer(questions[0], choice: 2), answer(questions[1], text: "x", risk_score: nil) ]).value[:outcome])
      .to eq("escalated")
  end

  it "refuses a choice that is not one of the proposed answers" do
    expect(call([ answer(questions[0], choice: 5), answer(questions[1], text: "x") ]).value[:outcome]).to eq("escalated")
  end

  it "refuses when the supporter is switched off on the project" do
    project.update!(supporter_enabled: false)
    expect(call([]).error.code).to eq("R403-SUPPORTER-001")
  end

  it "refuses a round of another organization" do
    other = create(:agent_host)
    result = described_class.call(host: other, round_id: round.id, payload: { "digest" => digest, "answers" => [] })
    expect(result.error.code).to eq("R404-SUPPORTER-001")
  end

  it "refuses answers to questions that changed meanwhile" do
    expect(call([], digest: "sha256:stale").error.code).to eq("R409-SUPPORTER-001")
  end

  it "returns the earlier outcome when the same round arrives twice" do
    first = call([ answer(questions[0], choice: 2), answer(questions[1], text: "x", risk_score: 9) ])
    again = call([ answer(questions[0], choice: 2), answer(questions[1], text: "x") ])

    expect(again.value[:outcome]).to eq(first.value[:outcome])
    expect(Agents::SupporterDecision.count).to eq(2)
  end
end
