# frozen_string_literal: true

require "rails_helper"

RSpec.describe Agents::TicketQueueDeferral, type: :model do
  subject(:deferral) { build(:agent_ticket_queue_deferral) }

  it "dichiara le associazioni tenant-scoped con host obbligatorio (host-first)" do
    expect(described_class.reflect_on_association(:organization).class_name).to eq("Organizations::Organization")
    expect(described_class.reflect_on_association(:ticket).class_name).to eq("Ticketing::Ticket")
    expect(described_class.reflect_on_association(:host).class_name).to eq("Agents::Host")
  end

  it "è valido host-first e rifiuta un'execution_phase sconosciuta" do
    host = create(:agent_host)
    ticket = create(:ticket, organization: host.organization)
    record = build(:agent_ticket_queue_deferral, organization: host.organization, host:, ticket:,
                                                  execution_phase: "triage")
    expect(record).to be_valid

    record.execution_phase = "sconosciuta"
    expect(record).not_to be_valid
    expect(record.errors.attribute_names).to include(:execution_phase)
  end

  it "conserva 0/1/N record storici e identifica gli attivi per host+ticket+phase" do
    now = Time.zone.parse("2026-07-14 12:00:00")
    host = create(:agent_host)
    ticket = create(:ticket, organization: host.organization)
    expect(described_class.active_for(host:, ticket:, execution_phase: "triage", at: now)).to be_empty

    expired = create(:agent_ticket_queue_deferral, organization: host.organization, host:, ticket:,
                                                    execution_phase: "triage", created_at: now - 1.minute, retry_at: now)
    active = create(:agent_ticket_queue_deferral, organization: host.organization, host:, ticket:,
                                                   execution_phase: "triage", created_at: now - 1.minute,
                                                   retry_at: now + 1.second)

    expect(described_class.active_for(host:, ticket:, execution_phase: "triage", at: now)).to contain_exactly(active)
    expect(described_class.where(host:, ticket:)).to contain_exactly(expired, active)
  end

  it "isola l'esclusione per fase e per host (un defer non copre altre fasi né altri host)" do
    now = Time.zone.parse("2026-07-14 12:00:00")
    host = create(:agent_host)
    other_host = create(:agent_host, organization: host.organization)
    ticket = create(:ticket, organization: host.organization)
    create(:agent_ticket_queue_deferral, organization: host.organization, host:, ticket:,
                                         execution_phase: "triage", created_at: now - 1.minute, retry_at: now + 1.second)

    expect(described_class.active_for(host:, ticket:, execution_phase: "triage", at: now)).to be_present
    expect(described_class.active_for(host:, ticket:, execution_phase: "planner", at: now)).to be_empty
    expect(described_class.active_for(host: other_host, ticket:, execution_phase: "triage", at: now)).to be_empty
  end

  it "preserva l'evidenza dopo la nullify dell'host e la elimina con il ticket secondo le FK" do
    record = create(:agent_ticket_queue_deferral)
    host = record.host
    ticket = record.ticket

    host.destroy!
    expect(record.reload.host_id).to be_nil

    expect { ticket.destroy! }.to change(described_class, :count).by(-1)
  end


  it "rifiuta associazioni valorizzate che appartengono a tenant diversi" do
    organization = create(:organization)
    foreign = create(:organization)
    record = build(
      :agent_ticket_queue_deferral,
      organization:,
      host: create(:agent_host, organization: foreign),
      ticket: create(:ticket, organization: foreign)
    )

    expect(record).not_to be_valid
    expect(record.errors.attribute_names).to include(:host, :ticket)
  end

  it "richiede host e ticket" do
    record = build(
      :agent_ticket_queue_deferral,
      organization: create(:organization), host: nil, ticket: nil
    )

    expect(record).not_to be_valid
    expect(record.errors.attribute_names).to include(:host, :ticket)
    expect(record.errors.attribute_names).not_to include(:agent)
  end
end
