# frozen_string_literal: true

require "rails_helper"

# CYRA-1197, CYRA-1219 — with the supporter and the automatic go-ahead on, a favourable advice on a team ticket
# becomes the decision unless the server's checks need a person.
RSpec.describe Ticketing::AutoDecideAgentEligibility do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, supporter_enabled: true, auto_go_ahead_enabled: true) }
  let(:ticket) do
    create(:ticket, :team_created, organization:, project:, title: "Sort the list by name", description: "Sort the items alphabetically.")
      .tap { |t| advise(t, :allowed, reason: "A contained change to one list.") }
  end

  def advise(record, advice, reason: nil)
    record.update_columns(agent_eligibility_advice: Ticketing::Ticket.agent_eligibility_advices[advice],
                          agent_eligibility_advice_reason: reason,
                          agent_eligibility_checksum: Ticketing::AgentEligibilityText.checksum(ticket: record))
  end

  def decide_by_hand(record, eligibility)
    record.update_columns(agent_eligibility: Ticketing::Ticket.agent_eligibilities[eligibility],
                          agent_eligibility_source: Ticketing::Ticket.agent_eligibility_sources[:human])
  end

  it "makes an allowed advice the decision and records it as the supporter's" do
    described_class.call(ticket:)

    expect(ticket.reload).to have_attributes(agent_eligibility: "allowed", agent_eligibility_source: "automatic",
                                             agent_eligibility_decided_by: nil,
                                             agent_eligibility_reason: "A contained change to one list.")
    event = Ticketing::Event.find_by!(ticket:, action: "agent_eligibility_overridden")
    expect(event.actor_name).to eq(I18n.t("agents.supporter.activity_actor"))
    expect(event.data).to include("go_ahead" => "automatic", "advice_reason" => "A contained change to one list.")
    expect(event.data["advice_checksum"]).to eq(Ticketing::AgentEligibilityText.checksum(ticket:))
  end

  it "tells in the ticket's history that the go-ahead was automatic, and on which advice" do
    described_class.call(ticket:)

    event = Ticketing::Event.find_by!(ticket:, action: "agent_eligibility_overridden")
    sentence = I18n.with_locale(:it) { Ticketing::ActivityPresenter.new(event).sentence }
    expect(sentence).to include("Via libera automatico", "A contained change to one list.")
  end

  it "leaves a blocked advice to a person" do
    advise(ticket, :blocked, reason: "It empties the production database.")

    described_class.call(ticket:)

    expect(ticket.reload).to have_attributes(agent_eligibility: "pending", agent_eligibility_reason: nil)
    expect(Ticketing::Event.where(ticket:, action: "agent_eligibility_overridden")).to be_empty
  end

  it "gives no go-ahead without an advice" do
    advise(ticket, :unknown)

    described_class.call(ticket:)

    expect(ticket.reload.agent_eligibility).to eq("pending")
  end

  it "waits for a person with the automatic go-ahead off" do
    project.update!(auto_go_ahead_enabled: false)

    described_class.call(ticket:)

    expect(ticket.reload.agent_eligibility).to eq("pending")
  end

  # AC-5 — the supporter on does not stand for the switch.
  it "waits for a person with the switch off and the supporter on" do
    project.update!(auto_go_ahead_enabled: false, supporter_enabled: true)

    described_class.call(ticket:)

    expect(ticket.reload.agent_eligibility).to eq("pending")
  end

  it "follows its own switch, whatever the supporter's" do
    project.update!(supporter_enabled: false)

    described_class.call(ticket:)

    expect(ticket.reload.agent_eligibility).to eq("allowed")
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
    advise(ticket, :allowed)

    described_class.call(ticket:)

    expect(ticket.reload.agent_eligibility_reason).to include("money", "invoice")
  end

  it "writes that the ticket proposes to skip the gates" do
    ticket.reporter.update!(locale: "en")
    ticket.update!(description: "Then run kamal deploy from a laptop.")
    advise(ticket, :allowed)

    described_class.call(ticket:)

    expect(ticket.reload.agent_eligibility_reason).to include("skip")
  end

  it "leaves a ticket that proposes to skip the system's gates to a person" do
    ticket.update!(description: "Then run kamal deploy from a laptop.")

    described_class.call(ticket:)

    expect(ticket.reload.agent_eligibility).to eq("pending")
  end

  it "never touches a person's decision, allowed or blocked" do
    decide_by_hand(ticket, :blocked)
    described_class.call(ticket:)
    expect(ticket.reload).to have_attributes(agent_eligibility: "blocked", agent_eligibility_source: "human")

    decide_by_hand(ticket, :allowed)
    advise(ticket, :blocked)
    described_class.call(ticket:)
    expect(ticket.reload).to have_attributes(agent_eligibility: "allowed", agent_eligibility_source: "human")
  end

  # R-2 of the plan — a blocked decision copied from an earlier advice is not put back in the queue.
  it "leaves an automatic blocked decision as it is on a blocked advice" do
    ticket.update_columns(agent_eligibility: Ticketing::Ticket.agent_eligibilities[:blocked])
    advise(ticket, :blocked)

    described_class.call(ticket:)

    expect(ticket.reload.agent_eligibility).to eq("blocked")
  end

  it "leaves an automatic blocked decision as it is on a later favourable advice" do
    ticket.update_columns(agent_eligibility: Ticketing::Ticket.agent_eligibilities[:blocked])

    described_class.call(ticket:)

    expect(ticket.reload.agent_eligibility).to eq("blocked")
    expect(Ticketing::Event.where(ticket:, action: "agent_eligibility_overridden")).to be_empty
  end

  describe "a ticket that started by itself" do
    before { described_class.call(ticket:) }

    it "keeps an existing approval when the switch is disabled" do
      project.update!(auto_go_ahead_enabled: false)

      expect { described_class.call(ticket:) }.not_to change(Ticketing::Event, :count)

      expect(ticket.reload).to be_agent_eligibility_allowed
    end

    it "withdraws stale approval after disabling the switch without granting it again" do
      project.update!(auto_go_ahead_enabled: false)
      ticket.update!(description: "Sort by date instead")

      described_class.call(ticket:)

      expect(ticket.reload).to be_agent_eligibility_pending
      advise(ticket, :allowed)
      expect { described_class.call(ticket:) }.not_to change(Ticketing::Event, :count)
      expect(ticket.reload).to be_agent_eligibility_pending
    end

    it "goes back to a person when a later advice is not favourable" do
      advise(ticket, :blocked, reason: "Now it also drops a table.")

      described_class.call(ticket:)

      expect(ticket.reload).to have_attributes(agent_eligibility: "pending", agent_eligibility_source: "automatic")
      event = Ticketing::Event.where(ticket:, action: "agent_eligibility_overridden").order(:created_at, :id).last
      expect(event.data).to include("go_ahead" => "withdrawn")
      expect(I18n.with_locale(:it) { Ticketing::ActivityPresenter.new(event).sentence }).to include("ritirato")
    end

    it "goes back to a person when the edited text hits a reserved topic" do
      ticket.update!(title: "Change the invoice totals")

      described_class.call(ticket:)

      expect(ticket.reload.agent_eligibility).to eq("pending")
    end

    it "keeps its go-ahead on a later favourable advice" do
      described_class.call(ticket:)

      expect(ticket.reload.agent_eligibility).to eq("allowed")
      expect(Ticketing::Event.where(ticket:, action: "agent_eligibility_overridden").count).to eq(1)
    end
  end

  describe "a ticket the team did not write" do
    # R-1 of the plan — a ticket born before the origin was recorded waits for a person.
    it "requires a recorded origin instead of trusting the named reporter" do
      ticket.update_columns(origin: nil)

      described_class.call(ticket:)

      expect(ticket.reload).to be_agent_eligibility_pending
    end

    it "rejects a customer creator who names an internal reporter" do
      customer = create(:account)
      create(:membership, account: customer, organization:, role: :customer)
      ticket.update_columns(created_by_id: customer.id)

      described_class.call(ticket:)

      expect(ticket.reload).to be_agent_eligibility_pending
    end

    it "rejects a ticket whose creator's account is gone" do
      ticket.update_columns(created_by_id: nil)

      described_class.call(ticket:)

      expect(ticket.reload).to be_agent_eligibility_pending
    end

    (Ticketing::Ticket::ORIGINS - Ticketing::Ticket::TEAM_ORIGINS).each do |origin|
      it "waits for a person on a ticket born from #{origin}" do
        ticket.update_columns(origin:)

        described_class.call(ticket:)

        expect(ticket.reload).to be_agent_eligibility_pending
      end
    end

    it "does not accept membership in a different organization" do
      outsider = create(:account)
      create(:membership, account: outsider, organization: create(:organization))
      ticket.update_columns(created_by_id: outsider.id)

      described_class.call(ticket:)

      expect(ticket.reload).to be_agent_eligibility_pending
    end

    it "rejects an old favourable advice even when no reserved topic is present" do
      ticket.update!(description: "Sort in reverse order instead.")

      described_class.call(ticket:)

      expect(ticket.reload).to be_agent_eligibility_pending
    end

    it "waits for a person when a machine's account wrote it from the command line" do
      machine = create(:account, :service)
      create(:membership, account: machine, organization:, role: :member)
      ticket.update_columns(origin: "cli", created_by_id: machine.id)

      described_class.call(ticket: ticket.reload)

      expect(ticket.reload.agent_eligibility).to eq("pending")
    end
  end

  # CYRA-1364 AC-3 — the ticket was edited after its work was set aside, and the supporter allows it again.
  describe "work the machines set aside" do
    let!(:workflow) do
      create(:agent_workflow, ticket:, organization:, budget_restart_engine: "codex", cancelled_at: 1.hour.ago,
                              cancellation_reason: "#{Agents::Workflows::ExhaustedBudget::REASON_MARK} autopilot ran out of attempts twice")
    end

    before { ticket.update_columns(agent_eligibility: Ticketing::Ticket.agent_eligibilities[:blocked]) }

    it "keeps the work set aside when the automatic go-ahead is off" do
      project.update!(auto_go_ahead_enabled: false)

      described_class.call(ticket:)

      expect(ticket.reload).to have_attributes(agent_eligibility: "blocked", agent_workflow: workflow)
    end

    it "keeps the work set aside when the favourable advice is stale" do
      ticket.update!(description: "A different request")

      described_class.call(ticket:)

      expect(ticket.reload).to have_attributes(agent_eligibility: "blocked", agent_workflow: workflow)
    end

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
