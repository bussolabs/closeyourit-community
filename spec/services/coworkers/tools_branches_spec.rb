require "rails_helper"

RSpec.describe Coworkers::Tools, "edge cases" do
  let(:organization) { create(:organization) }
  let(:account) { create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :owner) } }
  let(:project) { create(:project, organization: organization, key: "SHOP") }
  let!(:ticket) { create(:ticket, project: project, title: "Checkout fails") }
  let(:puck) { Coworkers::Puck.create!(organization: organization, account: account, name: "Triage", instructions: "Help") }
  let(:run) { Coworkers::Start.call(puck: puck, kind: "chat", input: "What is open on SHOP?").tap { |r| r.update!(status: "running") } }

  before do
    allow(Coworkers).to receive(:enabled?).and_return(true)
    allow(Coworkers::ExecuteJob).to receive(:perform_later)
    allow(Ticketing::FindSimilarTickets).to receive(:call).and_return(Result.ok([]))
  end

  def call(name, args, call_id: SecureRandom.uuid) = described_class.call(run: run, call_id: call_id, name: name, args: args)

  describe "arguments" do
    it "reads with empty arguments when the runtime sends none" do
      expect(call("list_projects", nil)[:projects].map { |row| row[:key] }).to eq([ "SHOP" ])
    end

    it "refuses arguments larger than the limit" do
      expect { call("search_tickets", { "project" => "x" * (described_class::MAX_ARGS_BYTES + 1) }) }
        .to raise_error(described_class::UnknownCall)
      expect(run.tool_calls.count).to eq(0)
    end
  end

  describe "answers" do
    it "shortens a long list that does not say how many rows it shows" do
      20.times { |index| create(:project, organization: organization, key: "L#{index.to_s.rjust(2, '0')}", name: "Long name " + ("y" * 120)) }
      result = call("list_projects", {})
      expect(result[:projects].to_json.size).to be <= described_class::LIST_CHARS
      expect(result[:projects].size).to be < 21
      expect(result).to include(total: 21)
      expect(result).not_to have_key(:showing)
    end

    it "passes an answer that is not a hash through unchanged" do
      allow(Assistant::Tools::Registry).to receive(:run).and_return("plain text")
      expect(call("list_projects", {})).to eq("plain text")
    end
  end

  describe "automation" do
    it "refuses to propose a fix for a ticket it cannot see" do
      expect(call("propose_agent_fix", { "code" => "NOPE-1" })).to eq(error: "No visible ticket with that code.")
      expect(run.action_proposals.count).to eq(0)
    end

    it "refuses to report on a ticket it cannot see" do
      expect(call("agent_fix_status", { "code" => "NOPE-1" })).to eq(error: "No visible ticket with that code.")
    end

    it "reports the phase of a running automation" do
      workflow = create(:agent_workflow, ticket: ticket)
      status = call("agent_fix_status", { "code" => ticket.code })
      expect(status[:phase]).to be_present
      expect(status[:phase]).to eq(workflow.reload.phase)
      expect(status[:pull_requests]).to eq([])
    end
  end

  describe "memory" do
    it "refuses an empty note" do
      expect(call("remember", { "note" => "   " })).to eq(error: "Empty note.")
      expect(puck.memory_notes.count).to eq(0)
    end

    it "refuses a new note while too many wait for the owner" do
      Coworkers::MemoryNote::MAX_PENDING.times { |index| puck.memory_notes.create!(run: run, body: "Note #{index}", scope: {}) }
      expect(call("remember", { "note" => "One more" })).to eq(error: "Too many notes wait for the owner.")
      expect(puck.memory_notes.where(body: "One more")).not_to exist
    end
  end

  describe "hand off" do
    it "refuses a third hand-off from the same run" do
      2.times do |index|
        helper = Coworkers::Puck.create!(organization: organization, account: account, name: "Helper #{index}", instructions: "x")
        Coworkers::Start.call(puck: helper, kind: "task", input: "x", account: account, parent_run: run).update!(status: "completed")
      end
      result = call("hand_off", { "puck" => "Helper 0", "request" => "More" })
      expect(result).to eq(error: "This run already handed off 2 pieces of work.")
      expect(run.child_runs.count).to eq(2)
    end
  end

  describe "rules" do
    it "reports a failure when an allowed action cannot be applied" do
      puck.rules.create!(action: "comment_ticket", decision: "allow")
      allow(Ticketing::AddComment).to receive(:call)
        .and_return(Result.err(AppError.new("Comment refused", code: "R422-COMMENT-001")))
      result = call("propose_comment", { "code" => ticket.code, "body" => "Looking into it" })
      expect(result).to include(status: "failed", message: "Comment refused")
      expect(run.action_proposals.sole).to have_attributes(status: "failed", error_code: "R422-COMMENT-001")
    end
  end
end
