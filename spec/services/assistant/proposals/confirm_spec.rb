# frozen_string_literal: true

require "rails_helper"

RSpec.describe Assistant::Proposals::Confirm do
  let(:organization) { create(:organization) }
  let(:account) do
    create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :owner) }
  end
  let(:project) { create(:project, organization: organization, key: "CYFL") }
  let(:ticket) { create(:ticket, project: project, title: "Webhook twice", description: "Body stays") }
  let(:conversation) { Assistant::Conversation.create!(account: account, organization: organization) }
  let(:reply) { conversation.messages.create!(organization: organization, role: :assistant, status: :complete, content: "ok") }

  def proposal(kind, payload, owner = account)
    Assistant::Proposal.create!(message: reply, organization: organization, account: owner, kind: kind, payload: payload)
  end

  def confirm(record) = described_class.call(proposal: record, account: account, organization: organization)

  before do
    allow(Ticketing::NotifyJob).to receive(:perform_later)
    create(:ticket_status, organization: organization, code: "open", label: "Open")
    create(:ticket_priority, organization: organization, code: "medium", label: "Medium")
  end

  it "creates the ticket and links it" do
    record = proposal(:create_ticket, "project_id" => project.id, "title" => "Login freezes",
                                      "description" => "Wrong password", "ticket_kind" => "bug")

    expect { expect(confirm(record)).to be_ok }.to change(Ticketing::Ticket, :count).by(1)

    expect(record.reload).to be_status_confirmed
    expect(record.result_type).to eq("Ticketing::Ticket")
    expect(Ticketing::Ticket.find(record.result_id).title).to eq("Login freezes")
  end

  it "creates one ticket even when confirmed twice" do
    record = proposal(:create_ticket, "project_id" => project.id, "title" => "Once", "description" => "Body",
                                      "ticket_kind" => "bug")

    confirm(record)
    second = confirm(record.reload)

    expect(second).to be_err
    expect(second.error.code).to eq("R409-PROPOSAL-001")
    expect(Ticketing::Ticket.where(title: "Once").count).to eq(1)
  end

  it "refuses a project the account cannot see now" do
    member = create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) }
    record = proposal(:create_ticket, { "project_id" => project.id, "title" => "Hidden", "description" => "Body",
                                        "ticket_kind" => "bug" }, member)

    result = described_class.call(proposal: record, account: member, organization: organization)

    expect(result.error.code).to eq("R404-PROPOSAL-001")
    expect(record.reload).to be_status_failed
    expect(Ticketing::Ticket.where(title: "Hidden")).to be_empty
  end

  it "refuses a status change without tickets.edit" do
    allow_any_instance_of(Authorization::Resolver).to receive(:can?).and_return(false)
    done = create(:ticket_status, organization: organization, code: "done", label: "Done", category: :done)
    record = proposal(:change_ticket_status, "ticket_id" => ticket.id, "status_id" => done.id)

    expect(confirm(record).error.code).to eq("R403-PROPOSAL-001")
    expect(ticket.reload.status_id).not_to eq(done.id)
  end

  it "changes the status" do
    done = create(:ticket_status, organization: organization, code: "done", label: "Done", category: :done)
    record = proposal(:change_ticket_status, "ticket_id" => ticket.id, "status_id" => done.id)

    expect(confirm(record)).to be_ok
    expect(ticket.reload.status_id).to eq(done.id)
  end

  it "changes only the priority and keeps the other fields" do
    high = create(:ticket_priority, organization: organization, code: "high", label: "High")
    record = proposal(:change_ticket_priority, "ticket_id" => ticket.id, "priority_id" => high.id)

    expect(confirm(record)).to be_ok
    ticket.reload
    expect(ticket.priority_id).to eq(high.id)
    expect([ ticket.title, ticket.description ]).to eq([ "Webhook twice", "Body stays" ])
  end

  it "assigns the ticket" do
    record = proposal(:assign_ticket, "ticket_id" => ticket.id, "assignee_id" => account.id)

    expect(confirm(record)).to be_ok
    expect(ticket.reload.assignee_id).to eq(account.id)
  end

  it "posts the comment" do
    record = proposal(:comment_ticket, "ticket_id" => ticket.id, "body" => "Done yesterday")

    expect { confirm(record) }.to change { ticket.comments.count }.by(1)
  end

  it "adds the todo on the person's own list only" do
    list = create(:todo_list, account: account, organization: organization)
    foreign = create(:todo_list, organization: organization)

    expect(confirm(proposal(:create_todo, "list_id" => list.id, "title" => "Call"))).to be_ok
    expect(confirm(proposal(:create_todo, "list_id" => foreign.id, "title" => "Nope")).error.code).to eq("R404-PROPOSAL-001")
    expect(list.items.pluck(:title)).to eq([ "Call" ])
  end

  it "creates the idea" do
    record = proposal(:create_idea, "project_id" => project.id, "title" => "Dark mode", "problem" => "Eyes hurt")

    expect { expect(confirm(record)).to be_ok }.to change { project.ideas.count }.by(1)
  end

  it "confirms a failed proposal again after an edit" do
    record = proposal(:create_ticket, "project_id" => project.id, "title" => "", "description" => "Body",
                                      "ticket_kind" => "bug")
    expect(confirm(record)).to be_err
    record.update!(payload: record.payload.merge("title" => "Now valid"))

    expect(confirm(record.reload)).to be_ok
  end
end
