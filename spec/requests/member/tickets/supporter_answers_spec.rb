# frozen_string_literal: true

require "rails_helper"

# CYAU-235 — an answer the supporter gave stays recognisable on the ticket, and waits "to review" until a
# person marks it seen.
RSpec.describe "Member supporter answers", type: :request do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, supporter_enabled: true) }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:owner) do
    create(:account).tap do |account|
      create(:membership, :owner, organization:, account:)
      create(:project_membership, account:, project:)
    end
  end
  let(:service_account) do
    create(:account, :service).tap { |a| create(:membership, account: a, organization:, role: :member) }
  end
  let(:host) { create(:agent_host, organization:, service_account:) }
  let(:round) { create(:agent_clarification, workflow: ticket.agent_workflow, questions: [ "Which one?" ]) }

  def supporter_answers!(source_status: "no_written_source")
    question = round.questions.first
    Agents::Supporters::AnswerRound.call(host:, round_id: round.id, payload: {
      "digest" => Agents::Supporters::NextRound.digest(round, [ question ]),
      "answers" => [ { "question_id" => question.id, "text" => "The first one", "risk_score" => 2, "confidence" => "high",
                       "source_status" => source_status, "rationale" => "It is the smaller change.",
                       "reasons_against" => "The second is more general.", "assumptions" => "None.",
                       "undo" => "Answer again on the ticket." } ]
    })
    Agents::SupporterDecision.find_by!(target_id: question.id)
  end

  before { post login_path, params: { email: owner.email, password: "Secret123!" } }

  it "labels the supporter's answer, says when it has no written source, and shows why" do
    supporter_answers!

    get member_ticket_path(ticket, tab: "questions")

    expect(response.body).to include('data-test="ticket-answer-supporter"', 'data-test="ticket-answer-no-written-source"',
                                      'data-test="ticket-answer-to-review"', "It is the smaller change.")
  end

  it "marks the answer seen, and it leaves the to-review list" do
    decision = supporter_answers!(source_status: "written")

    patch seen_member_ticket_supporter_decision_path(ticket, decision)

    expect(response).to redirect_to(member_ticket_path(ticket, tab: "questions"))
    expect(decision.reload.seen_by).to eq(owner)
    expect(Agents::SupporterDecision.to_review).to be_empty
  end

  it "does not let another organization mark it seen" do
    decision = supporter_answers!
    stranger = create(:account).tap { |a| create(:membership, :owner, organization: create(:organization), account: a) }
    delete logout_path rescue nil
    post login_path, params: { email: stranger.email, password: "Secret123!" }

    patch seen_member_ticket_supporter_decision_path(ticket, decision)

    expect(response).to have_http_status(:not_found)
    expect(decision.reload.seen_at).to be_nil
  end
end
