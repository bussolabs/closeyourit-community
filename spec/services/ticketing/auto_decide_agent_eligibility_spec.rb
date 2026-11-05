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
end
