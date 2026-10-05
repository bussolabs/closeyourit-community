# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Workflows::Cancel do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:ticket) { create(:ticket, organization:, project:, with_agent_workflow: true) }
  let(:workflow) { ticket.agent_workflow }
  let(:owner) { create(:account) }

  before { create(:membership, :owner, organization:, account: owner) }

  it "annulla il workflow, il tentativo attivo e il lease" do
    attempt = create(:agent_attempt, organization:, workflow:)
    create(:agent_lease, organization:, ticket:, host: attempt.host,
                         run_id: attempt.external_run_id, expires_at: 5.minutes.from_now)

    result = described_class.call(workflow:, actor: owner, reason: "Priorità cambiata")

    expect(result).to be_ok
    expect(workflow.reload).to have_attributes(cancelled_by: owner, cancellation_reason: "Priorità cambiata")
    expect(attempt.reload).to be_status_cancelled
    expect(ticket.reload.agent_lease).to be_nil
  end

  # Annullare l'automazione ferma gli agenti: non deve togliere il ticket dalle mani della persona
  # che intanto lo sta lavorando, che non c'entra nulla con il workflow annullato.
  it "non tocca la presa in carico di una persona" do
    account = create(:membership, organization:).account
    lease = create(:agent_lease, organization:, ticket:, host: nil, agent: nil, account:,
                                 run_id: "web:#{SecureRandom.uuid}", expires_at: 2.hours.from_now)

    expect(described_class.call(workflow:, actor: owner, reason: "Stop")).to be_ok
    expect(ticket.reload.agent_lease).to eq(lease)
  end

  it "annulla anche senza lease e non modifica tentativi già conclusi" do
    attempt = create(:agent_attempt, organization:, workflow:, status: :approved)

    expect(described_class.call(workflow:, actor: owner, reason: "Stop")).to be_ok
    expect(attempt.reload).to be_status_approved
  end

  it "richiede un gestore del progetto e una motivazione" do
    outsider = create(:account)

    expect(described_class.call(workflow:, actor: outsider, reason: "Stop").error.code).to eq("R403-WORKFLOW-002")
    expect(described_class.call(workflow:, actor: owner, reason: "  ").error.code).to eq("R422-WORKFLOW-002")
  end
end
