# frozen_string_literal: true

require "rails_helper"

RSpec.describe Assistant::Proposals::Confirm, "edge cases" do
  let(:organization) { create(:organization) }
  let(:account) do
    create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :owner) }
  end
  let(:project) { create(:project, organization: organization, key: "CYFL") }
  let(:ticket) { create(:ticket, project: project, title: "Webhook twice") }
  let(:conversation) { Assistant::Conversation.create!(account: account, organization: organization) }
  let(:reply) { conversation.messages.create!(organization: organization, role: :assistant, status: :complete, content: "ok") }

  def proposal(kind, payload)
    Assistant::Proposal.create!(message: reply, organization: organization, account: account, kind: kind, payload: payload)
  end

  before do
    allow(Ticketing::NotifyJob).to receive(:perform_later)
    create(:ticket_status, organization: organization, code: "open", label: "Open")
    create(:ticket_priority, organization: organization, code: "medium", label: "Medium")
  end

  it "refuses a proposal that belongs to someone else" do
    stranger = create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) }
    record = proposal(:comment_ticket, "ticket_id" => ticket.id, "body" => "Mine")

    result = described_class.call(proposal: record, account: stranger, organization: organization)

    expect(result.error.code).to eq("R409-PROPOSAL-001")
    expect(record.reload).to be_status_pending
    expect(ticket.comments.count).to eq(0)
  end

  it "refuses a new ticket on a project outside the run's frozen scope" do
    record = proposal(:create_ticket, "project_id" => project.id, "title" => "Out", "description" => "Body", "ticket_kind" => "bug")

    result = described_class.call(proposal: record, account: account, organization: organization, allowed_project_ids: [])

    expect(result.error.code).to eq("R404-PROPOSAL-001")
    expect(Ticketing::Ticket.where(title: "Out")).to be_empty
  end

  it "refuses a new idea on a project outside the run's frozen scope" do
    record = proposal(:create_idea, "project_id" => project.id, "title" => "Dark mode", "problem" => "Eyes hurt")

    result = described_class.call(proposal: record, account: account, organization: organization, allowed_project_ids: [])

    expect(result.error.code).to eq("R404-PROPOSAL-001")
    expect(project.ideas.count).to eq(0)
  end

  describe "start_agent_work" do
    it "lets the automation work the ticket without a video when no Puck prepared it" do
      allow(Ticketing::AttachToTicket).to receive(:call)
      record = proposal(:start_agent_work, "ticket_id" => ticket.id, "ticket_code" => ticket.code, "note" => "Please")

      expect(described_class.call(proposal: record, account: account, organization: organization)).to be_ok
      expect(ticket.reload.agent_eligibility).to eq("allowed")
      expect(Ticketing::AttachToTicket).not_to have_received(:call)
    end

    it "attaches nothing when the eligibility change fails" do
      allow(Ticketing::SetAgentEligibility).to receive(:call)
        .and_return(Result.err(AppError.new("Not allowed", code: "R422-ELIGIBILITY-001")))
      allow(Ticketing::AttachToTicket).to receive(:call)
      record = proposal(:start_agent_work, "ticket_id" => ticket.id, "ticket_code" => ticket.code)

      result = described_class.call(proposal: record, account: account, organization: organization)

      expect(result.error.code).to eq("R422-ELIGIBILITY-001")
      expect(record.reload).to have_attributes(status: "failed", error_code: "R422-ELIGIBILITY-001")
      expect(Ticketing::AttachToTicket).not_to have_received(:call)
    end
  end

  describe "external_tool" do
    let(:puck) { Coworkers::Puck.create!(organization: organization, account: account, name: "Ops", instructions: "Help") }

    before do
      allow(Coworkers).to receive(:enabled?).and_return(true)
      allow(Coworkers::ExecuteJob).to receive(:perform_later)
      allow(NetworkGuard).to receive_messages(resolved_public_address: "93.184.215.14", safe_url?: true, private_target?: false)
      allow(Coworkers::Mcp).to receive(:call_tool)
    end

    it "refuses an app call that no Puck prepared" do
      record = proposal(:external_tool, "connection_id" => SecureRandom.uuid, "tool" => "search", "arguments" => {})

      expect(described_class.call(proposal: record, account: account, organization: organization).error.code).to eq("R404-PROPOSAL-001")
      expect(Coworkers::Mcp).not_to have_received(:call_tool)
    end

    it "marks the proposal failed when the app answers with an error" do
      connection = puck.connections.create!(provider: "mcp", name: "Notion", url: "https://mcp.example.com/mcp", token: "secret-token",
                                            access: "write", tools: [ { "name" => "create-page", "input_schema" => { "type" => "object" } } ])
      run = Coworkers::Start.call(puck: puck, kind: "chat", input: "Go", account: account)
      record = Assistant::Proposal.create!(coworkers_run: run, organization: organization, account: account, kind: :external_tool,
                                           payload: { "connection_id" => connection.id, "tool" => "create-page" })
      allow(Coworkers::Mcp).to receive(:call_tool).and_return({ error: true, text: "Quota exceeded" })

      result = described_class.call(proposal: record, account: account, organization: organization)

      expect(result.error.code).to eq("R502-PROPOSAL-001")
      expect(Coworkers::Mcp).to have_received(:call_tool).with(connection, "create-page", {})
      expect(record.reload).to have_attributes(status: "failed", error_code: "R502-PROPOSAL-001")
    end
  end
end
