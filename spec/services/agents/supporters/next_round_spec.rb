# frozen_string_literal: true

require "rails_helper"

# CYAU-235 — the round a machine's supporter should answer next: open, on a project with the supporter on,
# in the machine's organization, not yet decided.
RSpec.describe Agents::Supporters::NextRound do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, supporter_enabled: true) }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:host) { create(:agent_host, organization:) }
  let!(:round) { create(:agent_clarification, workflow: ticket.agent_workflow, questions: [ "Which one?" ]) }

  it "serves the open round with its questions, the ticket and the supporter's engine" do
    item = described_class.call(host:).value

    expect(item).to include(round_id: round.id, engine: "codex", project_key: project.key)
    expect(item[:questions].map { |q| q[:body] }).to eq([ "Which one?" ])
    expect(item[:ticket]).to include(code: ticket.code, title: ticket.title)
    expect(item[:digest]).to start_with("sha256:")
  end

  it "names the OpenRouter model when the supporter answers with OpenCode" do
    create(:agent_automator_setting, organization:, supporter: "opencode", opencode_model: "anthropic/claude-sonnet-4.5")
    expect(described_class.call(host:).value).to include(engine: "opencode", model: "anthropic/claude-sonnet-4.5")
  end

  it "serves nothing when the project has the supporter off" do
    project.update!(supporter_enabled: false)
    expect(described_class.call(host:).value).to be_nil
  end

  it "serves nothing to a machine of another organization" do
    expect(described_class.call(host: create(:agent_host)).value).to be_nil
  end

  it "skips a round already decided" do
    question = round.questions.first
    Agents::SupporterDecision.create!(organization:, workflow: ticket.agent_workflow, target_type: "question",
                                      target_id: question.id, target_digest: described_class.digest(round, [ question ]),
                                      outcome: "escalated", engine: "codex", risk_score: 9)
    expect(described_class.call(host:).value).to be_nil
  end

  # CYRA-1197 — not a fixed window of the 20 oldest: when they are all decided, the next one is still served.
  it "serves an open round behind more than a page of rounds already decided" do
    decided = Array.new(described_class::PAGE) do |i|
      other = create(:ticket, organization:, project:, with_agent_workflow: true)
      create(:agent_clarification, workflow: other.agent_workflow, questions: [ "Old #{i}?" ], created_at: 2.hours.ago)
    end
    decided.each do |old|
      question = old.questions.first
      Agents::SupporterDecision.create!(organization:, workflow: old.workflow, target_type: "question", target_id: question.id,
                                        target_digest: described_class.digest(old, [ question ]), outcome: "escalated",
                                        engine: "codex", risk_score: 9)
    end

    expect(described_class.call(host:).value[:round_id]).to eq(round.id)
  end

  it "serves only rounds on projects the machine follows" do
    other = create(:ticket, organization:, project: create(:project, organization:, supporter_enabled: true),
                            with_agent_workflow: true)
    create(:agent_clarification, workflow: other.agent_workflow, questions: [ "Elsewhere?" ], created_at: 1.day.ago)
    host.update!(repositories: [ project.key ])

    expect(described_class.call(host:).value[:round_id]).to eq(round.id)
  end

  it "skips a round already answered" do
    round.update!(answered_at: Time.current)
    expect(described_class.call(host:).value).to be_nil
  end
end
