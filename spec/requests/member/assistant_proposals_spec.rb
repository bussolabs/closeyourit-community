# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::AssistantProposals", type: :request do
  let(:org) { create(:organization) }
  let(:account) { create(:account) }
  let(:project) { create(:project, organization: org, key: "CYFL") }
  let(:conversation) { Assistant::Conversation.create!(account: account, organization: org) }
  let(:reply) { conversation.messages.create!(organization: org, role: :assistant, status: :complete, content: "ok") }

  before do
    create(:membership, account: account, organization: org, role: :owner)
    create(:ticket_status, organization: org, code: "open", label: "Open")
    create(:ticket_priority, organization: org, code: "medium", label: "Medium")
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def ticket_proposal(title: "Login freezes")
    Assistant::Proposal.create!(message: reply, organization: org, account: account, kind: :create_ticket,
                                payload: { "project_id" => project.id, "project_key" => "CYFL", "title" => title,
                                           "description" => "Body", "ticket_kind" => "bug", "similar" => [] })
  end

  it "confirms and answers with the confirmed card" do
    proposal = ticket_proposal

    post confirm_member_assistant_conversation_proposal_path(conversation, proposal), as: :turbo_stream

    expect(response).to have_http_status(:ok)
    expect(response.body).to include(ActionView::RecordIdentifier.dom_id(proposal))
    expect(proposal.reload).to be_status_confirmed
  end

  it "edits the title before confirming" do
    proposal = ticket_proposal

    patch member_assistant_conversation_proposal_path(conversation, proposal),
          params: { proposal: { title: "Login freezes on Safari" } }, as: :turbo_stream

    expect(proposal.reload.payload["title"]).to eq("Login freezes on Safari")
    expect(proposal).to be_status_pending
  end

  it "ignores keys that are not editable for the kind" do
    proposal = ticket_proposal

    patch member_assistant_conversation_proposal_path(conversation, proposal),
          params: { proposal: { project_id: SecureRandom.uuid, list_id: "x" } }, as: :turbo_stream

    expect(proposal.reload.payload).not_to have_key("list_id")
  end

  it "discards and restores" do
    proposal = ticket_proposal

    post discard_member_assistant_conversation_proposal_path(conversation, proposal), as: :turbo_stream
    expect(proposal.reload).to be_status_discarded
    post restore_member_assistant_conversation_proposal_path(conversation, proposal), as: :turbo_stream
    expect(proposal.reload).to be_status_pending
  end

  it "confirms all open proposals and keeps going after a failure" do
    good = ticket_proposal(title: "Good")
    bad = ticket_proposal(title: "")

    # Each card is a full, independent domain action (ticket creation, notifications): its queries
    # repeat per card by design, bounded by the few proposals of one reply (CYRA-907).
    allow_n_plus_one do
      post member_assistant_conversation_message_confirm_all_proposals_path(conversation, reply), as: :turbo_stream
    end

    expect(good.reload).to be_status_confirmed
    expect(bad.reload).to be_status_failed
  end

  it "returns 404 on a proposal of another account" do
    other = create(:account).tap { |a| create(:membership, account: a, organization: org, role: :member) }
    foreign_conversation = Assistant::Conversation.create!(account: other, organization: org)
    foreign_reply = foreign_conversation.messages.create!(organization: org, role: :assistant, status: :complete, content: "ok")
    foreign = Assistant::Proposal.create!(message: foreign_reply, organization: org, account: other, kind: :create_todo,
                                          payload: { "title" => "x" })

    post confirm_member_assistant_conversation_proposal_path(foreign_conversation, foreign), as: :turbo_stream

    expect(response).to have_http_status(:not_found)
    expect(foreign.reload).to be_status_pending
  end

  it "renders the cards inside the conversation" do
    ticket_proposal

    get member_assistant_conversation_path(conversation)

    expect(response.body).to include("data-test=\"assistant-proposal\"")
  end

  it "ignores a chosen id outside the scope" do
    proposal = ticket_proposal
    hidden = create(:project, organization: create(:organization))

    patch member_assistant_conversation_proposal_path(conversation, proposal),
          params: { proposal: { project_id: hidden.id } }, as: :turbo_stream

    expect(proposal.reload.payload["project_id"]).to eq(project.id)
  end

  it "updates the label together with a chosen id in the scope" do
    proposal = ticket_proposal
    other = create(:project, organization: org, key: "CYRA")

    patch member_assistant_conversation_proposal_path(conversation, proposal),
          params: { proposal: { project_id: other.id } }, as: :turbo_stream

    expect(proposal.reload.payload).to include("project_id" => other.id, "project_key" => "CYRA")
  end
end
