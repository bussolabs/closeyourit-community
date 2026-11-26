# frozen_string_literal: true

require "rails_helper"

# CYRA-1364 — a ticket allowed again after its work was set aside starts over from triage, with a fresh budget.
RSpec.describe Agents::Workflows::ResumeSetAside do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, :agent_workable, organization:, project:, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:admin) { create(:account).tap { |account| create(:membership, account:, organization:, role: :admin) } }
  let(:editor) { create(:account).tap { |account| create(:membership, account:, organization:, role: :member) } }

  def set_aside!
    workflow.update!(budget_restart_engine: "codex", cancelled_at: 1.hour.ago,
                     cancellation_reason: "#{Agents::Workflows::ExhaustedBudget::REASON_MARK} autopilot ran out of attempts twice")
  end

  # AC-1 — an administrator allowing the ticket again starts the work over.
  it "replaces the set-aside run with a new one from triage, attempts reset" do
    set_aside!

    expect(described_class.call(ticket:, actor: admin).value).to eq(:restarted)

    fresh = ticket.reload.agent_workflow
    expect(fresh.id).not_to eq(workflow.id)
    expect(fresh).to have_attributes(triage_requested_at: be_present, budget_restart_engine: nil, cancelled_at: nil)
    expect(ticket.events.find_by(action: "workflow_resumed").actor).to eq(admin)
  end

  # AC-4 — the same role as the restart button: an editor is told an administrator has to do it.
  it "leaves the run closed when the person is not an administrator" do
    set_aside!

    expect(described_class.call(ticket:, actor: editor).value).to eq(:needs_admin)
    expect(ticket.reload.agent_workflow).to eq(workflow)
  end

  # AC-5 — a cancel a person decided is never undone by allowing the ticket.
  it "does not touch a run a person cancelled" do
    workflow.update!(cancelled_at: 1.hour.ago, cancelled_by: admin, cancellation_reason: "Duplicate")

    expect(described_class.call(ticket:, actor: admin).value).to be_nil
    expect(ticket.reload.agent_workflow).to eq(workflow)
  end

  it "does not touch a run that is still going" do
    expect(described_class.call(ticket:, actor: admin).value).to be_nil
    expect(ticket.reload.agent_workflow).to eq(workflow)
  end

  it "does nothing while the ticket is not allowed to the agents" do
    set_aside!
    ticket.update_columns(agent_eligibility: Ticketing::Ticket.agent_eligibilities[:blocked])

    expect(described_class.call(ticket:, actor: admin).value).to be_nil
  end

  # R-3 — an approved delivery owns its release number: never replaced, even if it looks set aside.
  it "never replaces an approved delivery" do
    set_aside!
    workflow.update_columns(autopilot_approved_at: 2.hours.ago)

    expect(described_class.call(ticket:, actor: admin).value).to be_nil
    expect(ticket.reload.agent_workflow).to eq(workflow)
  end

  describe "the server's own restart" do
    it "needs no person and says so in the history" do
      set_aside!

      expect(described_class.call(ticket:, by_server: true).value).to eq(:restarted)
      event = ticket.events.find_by(action: "workflow_resumed_automatically")
      expect(event.actor_name).to eq(I18n.t("agents.supporter.activity_actor"))
    end

    # Review finding — a run that always fails must not loop: past the cap, a person restarts it.
    it "stops restarting on its own past the per-ticket cap" do
      described_class::AUTOMATIC_LIMIT.times do
        Ticketing::RecordActivity.call(ticket:, action: "workflow_resumed_automatically", actor_name: "supporter")
      end
      set_aside!

      expect(described_class.call(ticket:, by_server: true).value).to eq(:limit_reached)
      expect(ticket.reload.agent_workflow).to eq(workflow)
    end

    it "does not count a person's restarts against the cap" do
      described_class::AUTOMATIC_LIMIT.times do
        Ticketing::RecordActivity.call(ticket:, action: "workflow_resumed", actor: admin)
      end
      set_aside!

      expect(described_class.call(ticket:, by_server: true).value).to eq(:restarted)
    end
  end

  describe ".outcome_key" do
    it "names a run a person cancelled, so the reply can say how to restart it" do
      workflow.update!(cancelled_at: 1.hour.ago, cancelled_by: admin, cancellation_reason: "Duplicate")

      expect(described_class.outcome_key(ticket.reload, Result.ok(nil))).to eq("cancelled")
    end

    it "says nothing when the run is going" do
      expect(described_class.outcome_key(ticket, Result.ok(nil))).to be_nil
    end
  end
end
