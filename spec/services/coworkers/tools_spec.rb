require "rails_helper"

RSpec.describe Coworkers::Tools do
  let(:organization) { create(:organization) }
  let(:account) { create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :owner) } }
  let(:project) { create(:project, organization: organization, key: "SHOP") }
  let!(:ticket) { create(:ticket, project: project, title: "Checkout fails") }
  let(:puck) { Coworkers::Puck.create!(organization: organization, account: account, name: "Triage", instructions: "Help") }
  let(:run) { Coworkers::Start.call(puck: puck, kind: "chat", input: "What is open on SHOP?") }

  before do
    allow(Coworkers::ExecuteJob).to receive(:perform_later)
    allow(Ticketing::FindSimilarTickets).to receive(:call).and_return(Result.ok([]))
    run.update!(status: "running")
  end

  def call(name, args, call_id: SecureRandom.uuid) = described_class.call(run: run, call_id: call_id, name: name, args: args)

  describe "declarations" do
    it "offers the assistant reads and proposals as JSON schema" do
      names = described_class.declarations.map { |tool| tool[:name] }
      expect(names).to include("search_tickets", "list_errors", "propose_ticket", "propose_comment")
      search = described_class.declarations.find { |tool| tool[:name] == "search_tickets" }
      expect(search[:input_schema]).to include(type: "object")
      expect(search[:input_schema][:properties][:mine]).to include(type: "boolean")
    end

    it "reaches the runtime inside the frozen context of the run" do
      expect(run.context["railsTools"].map { |tool| tool["name"] }).to include("search_tickets")
      expect(run.scope).to include("project_ids" => [ project.id ], "listed" => true)
    end
  end

  describe "reads" do
    it "answers with real tickets of a visible project" do
      result = call("search_tickets", { "project" => "SHOP" })
      expect(result[:tickets].map { |row| row[:title] }).to eq([ "Checkout fails" ])
    end

    it "does not read a project outside the frozen scope" do
      other = create(:project, organization: organization, key: "LATE")
      create(:ticket, project: other)
      expect(call("search_tickets", { "project" => "LATE" })).to include(:error)
    end

    it "stops reading a project whose access was revoked after the run started" do
      run.update!(scope: run.scope.merge("project_ids" => [ project.id ], "full_access" => false))
      allow(Authorization::ScopeSnapshot).to receive(:capture).and_call_original
      allow(Authorization::ScopeSnapshot).to receive(:capture).with(account: account, organization: organization)
        .and_return(Authorization::ScopeSnapshot.new(project_ids: [], group_ids: [], full_access: false))
      expect(call("search_tickets", { "project" => "SHOP" })).to include(:error)
    end

    it "shortens a long list for a Puck but keeps the real total" do
      create_list(:error_group, 30, project: project, title: "RuntimeError in Checkout " + ("x" * 80))
      result = call("list_errors", { "project" => "SHOP" })
      expect(result[:errors].to_json.size).to be <= described_class::LIST_CHARS
      expect(result[:errors].size).to be_between(1, 29)
      expect(result).to include(total: 30, showing: result[:errors].size)
    end

    it "keeps every row of a short list" do
      13.times { |index| create(:project, organization: organization, key: "P#{index.to_s.rjust(2, '0')}") }
      run.update!(status: "completed")
      fresh = Coworkers::Start.call(puck: puck, kind: "chat", input: "Which projects?").tap { |r| r.update!(status: "running") }
      result = described_class.call(run: fresh, call_id: SecureRandom.uuid, name: "list_projects", args: {})
      expect(result[:projects].size).to eq(14)
    end

    it "returns the first answer when the same call is sent again" do
      first = call("search_tickets", { "project" => "SHOP" }, call_id: "call-1")
      ticket.update!(title: "Renamed")
      second = call("search_tickets", { "project" => "SHOP" }, call_id: "call-1")
      expect(second.deep_symbolize_keys[:tickets].first[:title]).to eq(first[:tickets].first[:title])
      expect(run.tool_calls.count).to eq(1)
    end

    it "refuses a reused call id with different arguments" do
      call("search_tickets", { "project" => "SHOP" }, call_id: "call-1")
      expect { call("search_tickets", { "project" => "OTHER" }, call_id: "call-1") }.to raise_error(described_class::UnknownCall)
    end

    it "refuses unknown tools" do
      expect { call("drop_database", {}) }.to raise_error(described_class::UnknownCall)
    end

    it "does nothing once the run was stopped" do
      run.update!(stop_requested: true)
      expect(call("search_tickets", { "project" => "SHOP" })).to eq({ error: "This work was stopped." })
    end
  end

  describe "proposals and rules" do
    def comment = call("propose_comment", { "code" => ticket.code, "body" => "Looking into it" })

    it "waits for a person and tells the owner when there is no rule" do
      expect { expect(comment[:status]).to eq("awaiting_confirmation") }
        .to change { Alerting::Notification.where(event_type: :puck_decision_needed, account: account, via: :in_app).count }.by(1)
      expect(run.action_proposals.sole).to have_attributes(status: "pending", origin: "user")
      expect(ticket.comments.count).to eq(0)
    end

    it "marks the waiting notice read once the proposal is decided" do
      comment
      notices = Alerting::Notification.where(event_type: :puck_decision_needed, account: account)
      expect(notices.where(read_at: nil)).to exist
      run.action_proposals.sole.update!(status: :discarded)
      expect(notices.where(read_at: nil)).not_to exist
    end

    it "applies the action at once when the rule allows it" do
      rule = puck.rules.create!(action: "comment_ticket", decision: "allow")
      expect(comment[:status]).to eq("applied")
      expect(ticket.comments.sole.body).to start_with("Looking into it").and include("Prepared by Puck «Triage»").or include("Preparato da Puck «Triage»")
      expect(run.action_proposals.sole).to have_attributes(status: "confirmed", origin: "rule", coworkers_rule_id: rule.id)
    end

    it "blocks the action when the rule denies it" do
      puck.rules.create!(action: "comment_ticket", decision: "deny")
      expect(comment[:status]).to eq("blocked_by_rule")
      expect(run.action_proposals.sole).to have_attributes(status: "discarded", error_code: "R403-COWORKERS-002")
      expect(ticket.comments.count).to eq(0)
    end

    it "always asks before closing a ticket, whatever the rule says" do
      puck.rules.create!(action: "change_ticket_status", decision: "allow")
      done = create(:ticket_status, organization: organization, category: :done, code: "closed")
      result = call("propose_status", { "code" => ticket.code, "status" => "closed" })
      expect(result[:status]).to eq("awaiting_confirmation")
      expect(ticket.reload.status_id).not_to eq(done.id)
    end

    it "does not apply an allowed action on a project the run could not see" do
      puck.rules.create!(action: "comment_ticket", decision: "allow")
      proposal = Assistant::Proposal.create!(coworkers_run: run, organization: organization, account: account,
                                             kind: :comment_ticket, payload: { "ticket_id" => ticket.id, "body" => "x" })
      outcome = Assistant::Proposals::Confirm.call(proposal: proposal, account: account, organization: organization,
                                                   allowed_project_ids: [])
      expect(outcome).to be_err
      expect(ticket.comments.count).to eq(0)
    end
  end
end
