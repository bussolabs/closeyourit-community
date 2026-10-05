# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::RemoveDependency do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:actor) { create(:account) }
  let(:open_status) { create(:ticket_status, organization: org, code: "open", label: "Open") }
  let(:ticket) { create(:ticket, organization: org, project: project, status: open_status) }
  let(:blocker) { create(:ticket, organization: org, project: project, status: open_status) }
  let!(:dependency) { create(:ticket_dependency, ticket: ticket, blocker: blocker) }

  before { create(:membership, account: actor, organization: org, role: :owner) }

  it "rimuove la dipendenza e registra dependency_removed con snapshot code/title" do
    result = nil
    expect do
      result = described_class.call(ticket: ticket, dependency_id: dependency.id, actor: actor)
    end.to change(Connections::TicketDependency, :count).by(-1)

    expect(result).to be_ok
    event = ticket.events.find_by(action: "dependency_removed")
    expect(event.data).to include("code" => blocker.code, "title" => blocker.title)
    expect(event.actor).to eq(actor)
  end

  it "rinfresca la board del progetto del ticket dipendente (il badge può cadere)" do
    expect do
      described_class.call(ticket: ticket, dependency_id: dependency.id, actor: actor)
    end.to have_broadcasted_to(Realtime::Streams.project_board(project)).at_least(:once)
  end

  it "idempotente: una seconda rimozione (id già sparito) → 404 chiaro, non 500" do
    described_class.call(ticket: ticket, dependency_id: dependency.id, actor: actor)

    result = described_class.call(ticket: ticket, dependency_id: dependency.id, actor: actor)

    expect(result).to be_err
    expect(result.error.status).to eq(:not_found)
    expect(result.error.code).to eq("R404-TICKET-016")
  end

  it "anti-BOLA: una dependency di un ALTRO ticket non è rimovibile passando per questo → 404" do
    other_ticket = create(:ticket, organization: org, project: project, status: open_status)
    foreign = create(:ticket_dependency, ticket: other_ticket, blocker: blocker)

    result = nil
    expect do
      result = described_class.call(ticket: ticket, dependency_id: foreign.id, actor: actor)
    end.not_to change(Connections::TicketDependency, :count)

    expect(result).to be_err
    expect(result.error.status).to eq(:not_found)
    expect(foreign.reload).to be_present # la dependency altrui resta intatta
  end
end
