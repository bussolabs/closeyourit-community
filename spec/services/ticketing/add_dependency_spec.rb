# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::AddDependency do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:actor) { create(:account) }
  let(:open_status) { create(:ticket_status, organization: org, code: "open", label: "Open") }
  let(:ticket) { create(:ticket, organization: org, project: project, status: open_status) }
  let(:blocker) { create(:ticket, organization: org, project: project, status: open_status) }
  # Scope visibile = tutti i ticket dei progetti dell'org (come visible.tickets per un owner).
  let(:visible) { Ticketing::Ticket.where(project_id: org.projects.select(:id)) }

  before { create(:membership, account: actor, organization: org, role: :owner) }

  it "aggiunge il prerequisito e registra dependency_added con snapshot code/title dell'attore" do
    result = nil
    expect do
      result = described_class.call(ticket: ticket, blocker_id: blocker.id, visible_tickets: visible, actor: actor)
    end.to change(Connections::TicketDependency, :count).by(1)

    expect(result).to be_ok
    expect(ticket.reload.blockers).to include(blocker)
    event = ticket.events.find_by(action: "dependency_added")
    expect(event.data).to include("code" => blocker.code, "title" => blocker.title)
    expect(event.actor).to eq(actor)
  end

  it "rinfresca la board del progetto del ticket dipendente (badge 'bloccato' realtime)" do
    expect do
      described_class.call(ticket: ticket, blocker_id: blocker.id, visible_tickets: visible, actor: actor)
    end.to have_broadcasted_to(Realtime::Streams.project_board(project)).at_least(:once)
  end

  it "aggiunta CONCORRENTE dello stesso blocker (RecordNotUnique dall'indice DB) → 422, mai 500" do
    # La validazione applicativa uniqueness passa in entrambe le richieste (nessuna vede ancora
    # l'altra); a fallire è l'INSERT sull'indice unique. Deve diventare un errore di dominio, non un 500.
    allow_any_instance_of(Connections::TicketDependency).to receive(:save!).and_raise(ActiveRecord::RecordNotUnique.new("duplicate key"))

    result = nil
    expect do
      result = described_class.call(ticket: ticket, blocker_id: blocker.id, visible_tickets: visible, actor: actor)
    end.not_to raise_error

    expect(result).to be_err
    expect(result.error.status).to eq(:unprocessable_content)
  end

  it "blocker fuori dallo scope visibile → 404, nessuna dipendenza creata" do
    hidden = create(:ticket, organization: org, project: create(:project, organization: org), status: open_status)
    scoped = Ticketing::Ticket.where(project_id: project.id) # esclude il progetto di hidden

    result = nil
    expect do
      result = described_class.call(ticket: ticket, blocker_id: hidden.id, visible_tickets: scoped, actor: actor)
    end.not_to change(Connections::TicketDependency, :count)

    expect(result).to be_err
    expect(result.error.status).to eq(:not_found)
    expect(result.error.code).to eq("R404-TICKET-015")
  end

  it "cross-project intra-org è ammesso (blocker in un altro progetto visibile)" do
    cross = create(:ticket, organization: org, project: create(:project, organization: org), status: open_status)
    result = described_class.call(ticket: ticket, blocker_id: cross.id, visible_tickets: visible, actor: actor)

    expect(result).to be_ok
    expect(ticket.reload.blockers).to include(cross)
  end

  it "il ticket stesso come blocker → 422 (self-dependency), nessun evento" do
    result = described_class.call(ticket: ticket, blocker_id: ticket.id, visible_tickets: visible, actor: actor)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-TICKET-017")
    expect(ticket.events.where(action: "dependency_added")).to be_empty
  end

  it "blocker già associato → 422 (duplicato), nessun doppione" do
    create(:ticket_dependency, ticket: ticket, blocker: blocker)

    expect do
      result = described_class.call(ticket: ticket, blocker_id: blocker.id, visible_tickets: visible, actor: actor)
      expect(result).to be_err
      expect(result.error.code).to eq("R422-TICKET-017")
    end.not_to change(Connections::TicketDependency, :count)
  end

  it "dipendenza che chiuderebbe un ciclo → 422 dedicato (R422-TICKET-013)" do
    # blocker dipende già da ticket: aggiungere ticket→blocker chiuderebbe il ciclo.
    create(:ticket_dependency, ticket: blocker, blocker: ticket)

    result = described_class.call(ticket: ticket, blocker_id: blocker.id, visible_tickets: visible, actor: actor)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-TICKET-013")
  end
end
