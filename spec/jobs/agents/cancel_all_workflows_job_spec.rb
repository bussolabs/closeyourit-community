# frozen_string_literal: true

require "rails_helper"

# CYRA-867 — annulla tutte le lavorazioni aperte di UNA organizzazione, passando dall'annullamento singolo.
RSpec.describe Agents::CancelAllWorkflowsJob, type: :job do
  let(:org) { create(:organization) }
  let(:owner) { create(:account).tap { |a| create(:membership, account: a, organization: org, role: :owner) } }

  it "annulla le aperte dell'organizzazione e lascia stare quelle chiuse e quelle di altre organizzazioni" do
    open_one = create(:agent_workflow, organization: org)
    in_flight = create(:agent_workflow, :closer_staging_completed, organization: org)
    completed = create(:agent_workflow, organization: org, completed_at: 1.hour.ago)
    elsewhere = create(:agent_workflow, organization: create(:organization))

    described_class.perform_now(org.id, owner.id, "Ripartire da zero")

    expect(open_one.reload).to have_attributes(cancelled_by: owner, cancellation_reason: "Ripartire da zero")
    expect(in_flight.reload.cancelled_at).to be_present
    expect(completed.reload.cancelled_at).to be_nil
    expect(elsewhere.reload.cancelled_at).to be_nil
  end

  it "i ticket restano, senza automazione" do
    workflow = create(:agent_workflow, organization: org)

    described_class.perform_now(org.id, owner.id, "Ripartire da zero")

    expect(Ticketing::Ticket.exists?(workflow.ticket_id)).to be(true)
    expect(workflow.reload).to be_terminal
  end

  it "chi non è owner né admin non annulla niente, come nell'annullamento singolo" do
    member = create(:account).tap { |a| create(:membership, account: a, organization: org, role: :member) }
    workflow = create(:agent_workflow, organization: org)

    described_class.perform_now(org.id, member.id, "no")

    expect(workflow.reload.cancelled_at).to be_nil
  end
end
