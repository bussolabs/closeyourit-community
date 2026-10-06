require "rails_helper"

# CYRA-1002 — answering an automator question from the Questions tab or the CLI must close its round
# and put the work back in the triage queue, exactly like an answer from the old automation form.
RSpec.describe Ticketing::Questions::Reply, type: :service do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:author) do
    create(:account).tap { |a| create(:membership, account: a, organization:, role: :member) }
  end

  def round(questions:)
    create(:agent_clarification, workflow:, questions:)
  end

  it "closes the automator round and puts the work back in the triage queue" do
    clarification = round(questions: [ "Which rounding?" ])
    workflow.update!(triage_started_at: Time.current, triage_requested_at: nil)
    question = clarification.questions.first

    result = described_class.call(question:, author:, body: "Half away from zero.")

    expect(result).to be_ok
    expect(question.reload.answered_at).to be_present
    expect(question.answers.first.body).to eq("Half away from zero.")
    expect(clarification.reload.answered_at).to be_present
    expect(workflow.reload.triage_requested_at).to be_present
    expect(workflow.triage_started_at).to be_nil
  end

  it "answers only the named question of a round with several" do
    clarification = round(questions: [ "First?", "Second?" ])
    second = clarification.questions.order(:position).second

    described_class.call(question: second, author:, body: "Only the second.")

    rows = clarification.questions.order(:position)
    expect(rows.first.answered_at).to be_nil
    expect(rows.second.answers.first.body).to eq("Only the second.")
    expect(clarification.reload.answered_at).to be_present
  end

  it "refuses a withdrawn question without closing the round" do
    clarification = round(questions: [ "Which?" ])
    question = clarification.questions.first
    question.update!(closed_at: Time.current)
    workflow.update!(triage_requested_at: nil)

    result = described_class.call(question:, author:, body: "Too late.")

    expect(result).not_to be_ok
    expect(question.answers).to be_empty
    expect(clarification.reload.answered_at).to be_nil
    expect(workflow.reload.triage_requested_at).to be_nil
  end

  it "answers a question asked by a person without touching the work" do
    question = create(:ticket_question, ticket:, author:)
    workflow.update!(triage_requested_at: nil)

    result = described_class.call(question:, author:, body: "Done.")

    expect(result).to be_ok
    expect(question.reload.answered_at).to be_present
    expect(workflow.reload.triage_requested_at).to be_nil
  end

  it "records the answer on a concluded ticket without restarting the work" do
    clarification = round(questions: [ "Which?" ])
    done = create(:ticket_status, organization:, category: :done)
    ticket.update_columns(status_id: done.id)
    workflow.update!(triage_requested_at: nil)

    result = described_class.call(question: clarification.questions.first, author:, body: "That one.")

    expect(result).to be_ok
    expect(clarification.questions.first.reload.answered_at).to be_present
    expect(clarification.reload.answered_at).to be_nil
    expect(workflow.reload.triage_requested_at).to be_nil
  end
end
