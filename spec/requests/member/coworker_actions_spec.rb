require "rails_helper"

RSpec.describe "Member coworker actions and rules", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let!(:membership) { create(:membership, account: account, organization: organization, role: :owner) }
  let(:project) { create(:project, organization: organization, key: "SHOP") }
  let!(:ticket) { create(:ticket, project: project, title: "Checkout fails") }
  let!(:puck) { Coworkers::Puck.create!(account: account, organization: organization, name: "Triage", instructions: "Help") }
  let(:run) do
    puck.runs.create!(kind: "chat", input: "Comment please", status: "completed",
                      scope: Coworkers::Scope.capture(account: account, organization: organization))
  end
  let!(:proposal) do
    Assistant::Proposal.create!(coworkers_run: run, organization: organization, account: account, kind: :comment_ticket,
                                payload: { "ticket_id" => ticket.id, "ticket_code" => ticket.code, "ticket_title" => ticket.title, "body" => "On it" })
  end

  before do
    allow(Coworkers).to receive(:enabled?).and_return(true)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  it "shows the proposed action in the conversation and applies it on confirm" do
    get member_coworker_path(puck)
    expect(response.body).to include("coworkers-action-confirm", "Checkout fails")
    post confirm_member_coworker_proposal_path(puck, proposal)
    expect(ticket.comments.sole.body).to start_with("On it").and include("Puck «Triage»")
    expect(proposal.reload).to be_status_confirmed
  end

  it "discards a proposed action without applying it" do
    post discard_member_coworker_proposal_path(puck, proposal)
    expect(proposal.reload).to be_status_discarded
    expect(ticket.comments).to be_empty
  end

  it "does not confirm an action of another account's Puck" do
    stranger = create(:account)
    create(:membership, account: stranger, organization: organization, role: :member)
    other = Coworkers::Puck.create!(account: stranger, organization: organization, name: "Other", instructions: "x")
    post confirm_member_coworker_proposal_path(other, proposal)
    expect(response).to have_http_status(:not_found)
    expect(proposal.reload).to be_status_pending
  end

  it "saves a rule per kind of action and shows it in the rules panel" do
    patch member_coworker_rule_path(puck, "comment_ticket"), params: { decision: "allow" }
    expect(puck.rules.find_by(action: "comment_ticket").decision).to eq("allow")
    get member_coworker_path(puck, panel: "rules")
    expect(response.body).to include("coworkers-rules", 'data-decision="allow"')
  end

  it "refuses an unknown action or decision" do
    patch member_coworker_rule_path(puck, "drop_database"), params: { decision: "allow" }
    expect(response).to have_http_status(:not_found)
    patch member_coworker_rule_path(puck, "comment_ticket"), params: { decision: "always" }
    expect(puck.rules).to be_empty
  end
end
