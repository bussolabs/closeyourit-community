# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Assistant ticket proposal tools" do
  let(:organization) { create(:organization) }
  let(:account) do
    create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :owner) }
  end
  let(:project) { create(:project, organization: organization, key: "CYFL") }
  let(:ticket) { create(:ticket, project: project, title: "Webhook twice") }
  let(:conversation) { Assistant::Conversation.create!(account: account, organization: organization) }
  let(:reply) do
    conversation.messages.create!(organization: organization, role: :assistant, status: :streaming)
  end
  let(:context) do
    Assistant::Tools::Context.new(account: account, organization: organization, project_ids: [ project.id ],
                                  group_ids: [], full_access: false, reply_message_id: reply.id)
  end

  before do
    allow(Ticketing::FindSimilarTickets).to receive(:call).and_return(Result.ok([]))
  end

  def run(tool, args) = tool.new(context: context).call(args)

  it "proposes a ticket and creates no ticket" do
    expect {
      result = run(Assistant::Tools::ProposeTicket, { "project" => "cyfl", "title" => "Login freezes",
                                                      "description" => "Wrong password freezes login" })
      expect(result[:status]).to eq("awaiting_confirmation")
    }.not_to change(Ticketing::Ticket, :count)

    proposal = reply.proposals.sole
    expect(proposal).to be_kind_create_ticket
    expect(proposal.payload).to include("project_id" => project.id, "title" => "Login freezes", "similar" => [])
  end

  it "puts similar tickets in the payload" do
    allow(Ticketing::FindSimilarTickets).to receive(:call)
      .and_return(Result.ok([ Ticketing::FindSimilarTickets::Match.new(ticket: ticket, distance: 0.1, similarity: 90) ]))

    run(Assistant::Tools::ProposeTicket, { "project" => "CYFL", "title" => "Webhook received twice" })

    expect(reply.proposals.sole.payload["similar"]).to eq([ { "code" => ticket.code, "title" => "Webhook twice" } ])
  end

  it "answers not visible for a project outside the scope and saves nothing" do
    other = create(:project, organization: organization, key: "HIDE")

    result = run(Assistant::Tools::ProposeTicket, { "project" => other.key, "title" => "x" })

    expect(result[:error]).to be_present
    expect(reply.proposals).to be_empty
  end

  it "proposes a comment on a visible ticket" do
    run(Assistant::Tools::ProposeComment, { "code" => ticket.code, "body" => "Done yesterday" })

    expect(reply.proposals.sole.payload).to include("ticket_id" => ticket.id, "body" => "Done yesterday")
  end

  it "proposes a status by spoken name and records the current one" do
    done = create(:ticket_status, organization: organization, code: "done", label: "Done", category: :done)

    run(Assistant::Tools::ProposeStatus, { "code" => ticket.code, "status" => "done" })

    expect(reply.proposals.sole.payload).to include("status_id" => done.id, "from_label" => ticket.status.display_label)
  end

  it "answers with the valid names when the status is unknown" do
    result = run(Assistant::Tools::ProposeStatus, { "code" => ticket.code, "status" => "nonsense" })

    expect(result[:error]).to include(ticket.status.display_label)
  end

  it "proposes a priority" do
    high = create(:ticket_priority, organization: organization, code: "high", label: "High")

    run(Assistant::Tools::ProposePriority, { "code" => ticket.code, "priority" => "High" })

    expect(reply.proposals.sole.payload).to include("priority_id" => high.id)
  end

  it "proposes an assignee among the organization members, me included" do
    run(Assistant::Tools::ProposeAssignee, { "code" => ticket.code, "assignee" => "me" })

    expect(reply.proposals.sole.payload).to include("assignee_id" => account.id)
  end

  it "answers not visible for an unknown ticket code" do
    result = run(Assistant::Tools::ProposeComment, { "code" => "CYFL-9999", "body" => "x" })

    expect(result[:error]).to be_present
  end
end
