# frozen_string_literal: true

require "rails_helper"

# CYRA-1197 — with the supporter on, the AI's advice becomes the decision unless the server's checks need a person.
RSpec.describe Ticketing::AutoDecideAgentEligibility do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, supporter_enabled: true) }
  let(:ticket) do
    create(:ticket, organization:, project:, title: "Sort the list by name", description: "Sort the items alphabetically.")
      .tap { |t| t.update_columns(agent_eligibility_advice: Ticketing::Ticket.agent_eligibility_advices[:allowed]) }
  end

  it "makes an allowed advice the decision and records it as the supporter's" do
    described_class.call(ticket:)

    expect(ticket.reload).to have_attributes(agent_eligibility: "allowed", agent_eligibility_source: "automatic",
                                             agent_eligibility_decided_by: nil)
    event = Ticketing::Event.find_by!(ticket:, action: "agent_eligibility_overridden")
    expect(event.actor_name).to eq(I18n.t("agents.supporter.activity_actor"))
  end

  it "follows a blocked advice too" do
    ticket.update_columns(agent_eligibility_advice: Ticketing::Ticket.agent_eligibility_advices[:blocked])

    described_class.call(ticket:)

    expect(ticket.reload.agent_eligibility).to eq("blocked")
  end

  it "leaves a ticket on a reserved topic to a person" do
    ticket.update!(title: "Change the invoice totals")

    described_class.call(ticket:)

    expect(ticket.reload.agent_eligibility).to eq("pending")
  end

  # CYRA-1340 — a ticket held for a person says why, instead of waiting in silence.
  it "writes which reserved topic holds the ticket for a person" do
    ticket.reporter.update!(locale: "en")
    ticket.update!(title: "Change the invoice totals")

    described_class.call(ticket:)

    expect(ticket.reload.agent_eligibility_reason).to include("money", "invoice")
  end

  it "writes that the ticket proposes to skip the gates" do
    ticket.reporter.update!(locale: "en")
    ticket.update!(description: "Then run kamal deploy from a laptop.")

    described_class.call(ticket:)

    expect(ticket.reload.agent_eligibility_reason).to include("skip")
  end

  it "leaves a ticket that proposes to skip the system's gates to a person" do
    ticket.update!(description: "Then run kamal deploy from a laptop.")

    described_class.call(ticket:)

    expect(ticket.reload.agent_eligibility).to eq("pending")
  end

  it "never touches a person's decision" do
    ticket.update_columns(agent_eligibility: Ticketing::Ticket.agent_eligibilities[:blocked],
                          agent_eligibility_source: Ticketing::Ticket.agent_eligibility_sources[:human])

    described_class.call(ticket:)

    expect(ticket.reload.agent_eligibility).to eq("blocked")
  end

  it "does nothing without an advice or with the supporter off" do
    project.update!(supporter_enabled: false)
    described_class.call(ticket:)
    expect(ticket.reload.agent_eligibility).to eq("pending")

    project.update!(supporter_enabled: true)
    ticket.update_columns(agent_eligibility_advice: Ticketing::Ticket.agent_eligibility_advices[:unknown])
    described_class.call(ticket:)
    expect(ticket.reload.agent_eligibility).to eq("pending")
  end

  # CYRA-1364 AC-3 — the ticket was edited after its work was set aside, and the supporter allows it again.
  describe "work the machines set aside" do
    let!(:workflow) do
      create(:agent_workflow, ticket:, organization:, budget_restart_engine: "codex", cancelled_at: 1.hour.ago,
                              cancellation_reason: "#{Agents::Workflows::ExhaustedBudget::REASON_MARK} autopilot ran out of attempts twice")
    end

    before { ticket.update_columns(agent_eligibility: Ticketing::Ticket.agent_eligibilities[:blocked]) }

    it "starts over from triage without anybody pressing anything" do
      described_class.call(ticket:)

      fresh = ticket.reload.agent_workflow
      expect(fresh.id).not_to eq(workflow.id)
      expect(fresh).to have_attributes(triage_requested_at: be_present, budget_restart_engine: nil, cancelled_at: nil)
      expect(Ticketing::Event.where(ticket:, action: "workflow_resumed_automatically").count).to eq(1)
    end

    # Review finding — a run that always fails stops coming back on its own after the cap.
    it "leaves the run closed once the server has restarted it as often as allowed" do
      Agents::Workflows::ResumeSetAside::AUTOMATIC_LIMIT.times do
        Ticketing::RecordActivity.call(ticket:, action: "workflow_resumed_automatically", actor_name: "supporter")
      end

      described_class.call(ticket:)

      expect(ticket.reload).to have_attributes(agent_eligibility: "allowed", agent_workflow: workflow)
    end

    it "does not restart a run a person cancelled" do
      workflow.update!(cancelled_by: create(:account), cancellation_reason: "Not needed any more")

      described_class.call(ticket:)

      expect(ticket.reload.agent_workflow).to eq(workflow)
    end
  end
end
