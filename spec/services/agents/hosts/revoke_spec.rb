# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::Hosts::Revoke do
  def host_with_project_access(project)
    account = Accounts::Service::Create.call(organization: project.organization, name: "Lease contender",
      handle: "lease_contender", project_ids: [ project.id ]).value
    create(:agent_host, organization: project.organization, service_account: account)
  end

  it "revoca idempotentemente host e singolo token attivo" do
    registration = Agents::Hosts::Register.call(
      organization: create(:organization), fingerprint: "machine-abc",
      hostname: "runner-1", platform: "linux", arch: "amd64"
    ).value

    described_class.call(host: registration[:host])
    first_revoked_at = registration[:host].reload.revoked_at
    described_class.call(host: registration[:host])

    expect(registration[:host].reload.revoked_at).to eq(first_revoked_at)
    expect(registration[:token].reload).to be_revoked
  end

  it "rilascia atomicamente le lease e rende subito acquisibili i ticket" do
    organization = create(:organization)
    project = create(:project, organization:, key: "CYAU")
    ticket = create(:ticket, organization:, project:)
    host = create(:agent_host, organization:)
    contender = host_with_project_access(project)
    create(:agent_lease, organization:, ticket:, host:, run_id: "revoked-run")

    result = described_class.call(host:)
    acquisition = Agents::Leases::Acquire.call(
      organization:,
      holder: Agents::Leases::Holder.host(contender),
      ticket_reference: ticket.code,
      params: {
        ticket: ticket.code,
        host_id: contender.id,
        run_id: "next-run",
        agent: "triage",
        ttl_seconds: 60
      }
    )

    expect(result).to be_ok
    expect(acquisition).to be_ok
    expect(acquisition.value.lease).to have_attributes(host: contender, run_id: "next-run")
    expect(Agents::Leases::Tombstone.where(ticket:, host:, run_id: "revoked-run")).to exist
  end

  it "impedisce a un'operazione con istanza host obsoleta di creare lease dopo la revoca" do
    organization = create(:organization)
    project = create(:project, organization:, key: "CYAU")
    ticket = create(:ticket, organization:, project:)
    host = host_with_project_access(project)
    stale_host = Agents::Host.find(host.id)
    described_class.call(host:)

    result = Agents::Leases::Acquire.call(
      organization:,
      holder: Agents::Leases::Holder.host(stale_host),
      ticket_reference: ticket.code,
      params: {
        ticket: ticket.code,
        host_id: stale_host.id,
        run_id: "late-run",
        agent: "triage",
        ttl_seconds: 60
      }
    )

    expect(result.error).to have_attributes(code: "R403-LEASE-001", status: :forbidden)
    expect(Agents::Lease.where(ticket:)).not_to exist
  end
end
