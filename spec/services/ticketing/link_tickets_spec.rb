# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::LinkTickets do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:actor) { create(:account) }
  let(:ticket) { create(:ticket, organization: org, project: project) }

  def other_ticket(title: "Preesistente")
    create(:ticket, organization: org, project: project, title: title)
  end

  it "collega più bersagli in un colpo e registra l'evento su tutti e due i capi" do
    first = other_ticket(title: "Primo")
    second = other_ticket(title: "Secondo")

    result = described_class.call(ticket: ticket, targets: [ first, second ], kind: :related, actor: actor)

    expect(result).to be_ok
    expect(result.value.map(&:code)).to eq([ first.code, second.code ])
    expect(ticket.links.pluck(:related_id)).to match_array([ first.id, second.id ])
    expect(Ticketing::Event.where(action: "linked", ticket: ticket).count).to eq(2)
    expect(Ticketing::Event.where(action: "linked", ticket: first).count).to eq(1)
  end

  it "scrive il kind chiesto dal chiamante" do
    target = other_ticket

    described_class.call(ticket: ticket, targets: [ target ], kind: :duplicate, actor: actor)

    expect(ticket.links.first).to be_kind_duplicate
  end

  it "salta il ticket stesso invece di far fallire tutto il lotto" do
    target = other_ticket

    result = described_class.call(ticket: ticket, targets: [ ticket, target ], kind: :related, actor: actor)

    expect(result.value.map(&:id)).to eq([ target.id ])
    expect(ticket.links.count).to eq(1)
  end

  it "salta un collegamento già esistente: spuntare due volte non è un errore" do
    target = other_ticket
    described_class.call(ticket: ticket, targets: [ target ], kind: :related, actor: actor)

    result = described_class.call(ticket: ticket, targets: [ target ], kind: :related, actor: actor)

    expect(result).to be_ok
    expect(result.value).to eq([])
    expect(ticket.links.count).to eq(1)
  end

  it "un bersaglio di un'altra organizzazione non viene collegato e non butta via il ticket" do
    stranger = create(:ticket, organization: create(:organization))

    result = described_class.call(ticket: ticket, targets: [ stranger ], kind: :related, actor: actor)

    expect(result).to be_ok
    expect(result.value).to eq([])
    expect(ticket.links.count).to eq(0)
  end

  it "un bersaglio cancellato mentre si salva non fa saltare il resto del lotto" do
    survivor = other_ticket(title: "Resta")
    doomed = other_ticket(title: "Sparisce")
    # Sparisce fra la lettura e la scrittura: il vincolo del database rifiuta la riga, e senza il
    # savepoint l'intera transazione sarebbe abortita — con il ticket nuovo già creato.
    Ticketing::Ticket.where(id: doomed.id).delete_all

    result = described_class.call(ticket: ticket, targets: [ doomed, survivor ], kind: :related,
                                  actor: actor)

    expect(result).to be_ok
    expect(result.value.map(&:id)).to eq([ survivor.id ])
    expect(ticket.links.pluck(:related_id)).to eq([ survivor.id ])
  end

  it "nessun bersaglio → nessuna scrittura" do
    expect { described_class.call(ticket: ticket, targets: [], kind: :related, actor: actor) }
      .not_to change(Connections::TicketLink, :count)
  end
end
