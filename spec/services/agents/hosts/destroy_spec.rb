# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Hosts::Destroy do
  let(:organization) { create(:organization) }

  def plan_for(workflow:, attempt:)
    Agents::Plan.create!(workflow:, attempt:, technical_analysis: "analisi", ticket_snapshot_digest: "digest")
  end

  it "elimina host, credenziali e storico" do
    registration = Agents::Hosts::Register.call(
      organization:, fingerprint: "machine-abc",
      hostname: "host-dismesso", platform: "linux", arch: "arm64"
    ).value
    host = registration[:host]
    workflow = create(:agent_workflow, organization:)
    attempt = create(:agent_attempt, workflow:, host:)
    create(:agent_clarification, workflow:, attempt:)
    plan_for(workflow:, attempt:)

    result = described_class.call(host:)

    expect(result).to be_ok
    expect(Agents::Host.where(id: host.id)).not_to exist
    expect(Agents::Attempt.where(id: attempt.id)).not_to exist
    expect(Agents::Plan.where(attempt_id: attempt.id)).not_to exist
    expect(Agents::Clarification.where(attempt_id: attempt.id)).not_to exist
    expect(Agents::HostToken.where(id: registration[:token].id)).not_to exist
  end

  # Il lease sopravviverebbe al giro solo se qualcuno lo riacquistasse nel mezzo: Revoke lo rilascia
  # prendendo i lock nell'ordine del dispatch, ed è per quello che sta dentro l'eliminazione.
  it "libera i ticket che la macchina teneva sotto lease" do
    host = create(:agent_host, organization:)
    ticket = create(:ticket, organization:)
    create(:agent_lease, organization:, ticket:, host:, expires_at: 2.hours.ago)

    described_class.call(host:)

    expect(Agents::Lease.where(ticket:)).not_to exist
  end

  it "riporta quanto ha cancellato, per dirlo a chi ha premuto" do
    host = create(:agent_host, organization:)
    workflow = create(:agent_workflow, organization:)
    attempt = create(:agent_attempt, workflow:, host:)
    plan_for(workflow:, attempt:)

    result = described_class.call(host:)

    expect(result.value).to include(hostname: host.hostname, attempts: 1, plans: 1, clarifications: 0)
  end

  it "rifiuta la macchina che sta ancora lavorando, e non tocca niente" do
    host = create(:agent_host, organization:)
    ticket = create(:ticket, organization:)
    create(:agent_lease, organization:, ticket:, host:, expires_at: 1.hour.from_now)

    result = described_class.call(host:)

    expect(result.error).to have_attributes(code: "R422-AGENT-008", status: :unprocessable_content)
    expect(Agents::Host.where(id: host.id)).to exist
    expect(host.reload.revoked_at).to be_nil
  end

  # Il caso vero della macchina dimenticata accesa e poi spenta: i lavori restano "in esecuzione" a
  # database perché nessuno li ha chiusi. Se bloccassero l'eliminazione, quell'host sarebbe eterno.
  it "elimina la macchina ferma con lavori rimasti aperti a database" do
    host = create(:agent_host, organization:)
    workflow = create(:agent_workflow, organization:)
    create(:agent_attempt, workflow:, host:, status: :running)
    create(:agent_lease, organization:, host:, expires_at: 2.hours.ago)

    result = described_class.call(host:)

    expect(result).to be_ok
    expect(Agents::Host.where(id: host.id)).not_to exist
  end

  it "conta lo storico prima di cancellarlo, per la richiesta di conferma" do
    host = create(:agent_host, organization:)
    workflow = create(:agent_workflow, organization:)
    attempt = create(:agent_attempt, workflow:, host:)
    create(:agent_clarification, workflow:, attempt:)
    plan_for(workflow:, attempt:)

    expect(described_class.history_size(host)).to eq(attempts: 1, plans: 1, clarifications: 1)
  end
end
