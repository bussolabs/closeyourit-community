# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::ChangeMilestone do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:status) { create(:ticket_status, organization: org) }
  let(:priority) { create(:ticket_priority, organization: org) }
  let(:ticket) { create(:ticket, organization: org, project: project, status: status, priority: priority) }
  let(:milestone) { create(:milestone, project: project) }
  let(:actor) { ticket.reporter }

  it "assegna la milestone (Result.ok) e registra l'evento" do
    expect do
      result = described_class.call(organization: org, ticket: ticket, milestone_id: milestone.id, actor: actor)
      expect(result).to be_ok
    end.to change { ticket.reload.milestone }.from(nil).to(milestone)
    expect(ticket.events.where(action: "milestone_changed")).to exist
  end

  it "rimuove la milestone quando milestone_id è blank" do
    ticket.update!(milestone: milestone)
    described_class.call(organization: org, ticket: ticket, milestone_id: "", actor: actor)
    expect(ticket.reload.milestone).to be_nil
  end

  it "milestone di un'altra org → R422-TICKET-004 (anti-BOLA), ticket invariato" do
    foreign = create(:milestone, project: create(:project))
    result = described_class.call(organization: org, ticket: ticket, milestone_id: foreign.id, actor: actor)
    expect(result).to be_err
    expect(result.error.code).to eq("R422-TICKET-004")
    expect(ticket.reload.milestone).to be_nil
  end

  it "stessa milestone → no-op (nessun evento)" do
    ticket.update!(milestone: milestone)
    expect do
      described_class.call(organization: org, ticket: ticket, milestone_id: milestone.id, actor: actor)
    end.not_to change(Ticketing::Event, :count)
  end
end
