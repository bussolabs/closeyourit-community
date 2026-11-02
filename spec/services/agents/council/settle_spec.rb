# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Council::Settle do
  let(:organization) { create(:organization) }
  let(:service_account) do
    create(:account, :service).tap { |a| create(:membership, account: a, organization:, role: :owner) }
  end
  let(:host) { create(:agent_host, organization:, service_account:) }
  let(:project) { create(:project, organization:, council_enabled: true) }
  let!(:open_status) { create(:ticket_status, organization:, category: :open) }
  let!(:priority) { create(:ticket_priority, organization:, code: "medium") }
  let(:run) { create(:agent_council_run, organization:, project:, host:, mode: "on") }

  before do
    allow(Ticketing::FindSimilarTickets).to receive(:call).and_return(Result.ok([]))
    allow(Ideas::FindSimilarIdeas).to receive(:call).and_return(Result.ok([]))
  end

  def proposal(ref = "claude-1")
    { "ref" => ref, "proposer" => "claude", "title" => "Index tickets by status #{ref}",
      "problem" => "The list is slow", "solution" => "Add an index", "kind" => "code", "risk" => "low",
      "engine" => "codex", "model" => "gpt-6-astra" }
  end

  def approve(ref = "claude-1") = { "ref" => ref, "critic" => "codex", "vote" => "approve", "risk" => "low", "reason" => "ok" }

  def settle(proposals, critiques, failure: nil)
    described_class.call(host:, run_id: run.id,
                         payload: { "proposals" => proposals, "critiques" => critiques, "failure" => failure })
  end

  it "opens a ticket for an approved proposal and remembers the engine and model" do
    expect(settle([ proposal ], [ approve ])).to be_ok
    record = Agents::CouncilProposal.sole
    expect(record).to have_attributes(outcome: "ticket", suggested_engine: "codex", suggested_model: "gpt-6-astra")
    expect(record.ticket).to have_attributes(project:, kind: "task")
    expect(record.ticket.description).to include("Add an index")
    expect(run.reload).to have_attributes(status: "completed")
  end

  it "records a rejected proposal without creating anything" do
    settle([ proposal ], [ approve.merge("vote" => "reject") ])
    expect(Agents::CouncilProposal.sole.outcome).to eq("rejected")
    expect(Ticketing::Ticket.count).to eq(0)
  end

  it "turns an approved proposal into an idea when three council tickets are open" do
    3.times do |i|
      ticket = create(:ticket, organization:, project:, status: open_status)
      create(:agent_council_proposal, council_run: run, ref: "old-#{i}", outcome: "ticket", ticket:)
    end
    settle([ proposal ], [ approve ])
    expect(Agents::CouncilProposal.find_by(ref: "claude-1")).to have_attributes(outcome: "idea", ticket_id: nil)
    expect(Ideas::Idea.where(project:).count).to eq(1)
  end

  it "creates nothing in dry run" do
    run.update!(mode: "dry_run")
    settle([ proposal ], [ approve ])
    expect(Agents::CouncilProposal.sole.outcome).to eq("dry_ticket")
    expect(Ticketing::Ticket.count + Ideas::Idea.count).to eq(0)
  end

  it "skips a duplicate of an open ticket" do
    match = Ticketing::FindSimilarTickets::Match.new(ticket: create(:ticket, organization:, project:),
                                                     distance: 0.05, similarity: 95)
    allow(Ticketing::FindSimilarTickets).to receive(:call).and_return(Result.ok([ match ]))
    settle([ proposal ], [ approve ])
    expect(Agents::CouncilProposal.find_by(ref: "claude-1").outcome).to eq("duplicate")
  end

  it "creates nothing when duplicates cannot be checked" do
    allow(Ticketing::FindSimilarTickets).to receive(:call).and_return(Result.err(AppError.new("down", code: "R503-AI-001")))
    settle([ proposal ], [ approve ])
    expect(Agents::CouncilProposal.sole.outcome).to eq("unchecked")
    expect(Ticketing::Ticket.count).to eq(0)
  end

  it "closes the slice as failed when the machine reports a failure" do
    settle([], [], failure: { "kind" => "quota", "detail" => "claude: model quota exhausted" })
    expect(run.reload).to have_attributes(status: "failed", failure_kind: "quota")
  end

  it "refuses a slice already closed" do
    run.update!(status: "completed", finished_at: Time.current)
    expect(settle([ proposal ], [ approve ]).error.code).to eq("R409-COUNCIL-001")
  end

  it "refuses a slice of another organization" do
    other = create(:agent_council_run)
    result = described_class.call(host:, run_id: other.id, payload: {})
    expect(result.error.code).to eq("R404-COUNCIL-001")
  end
end
