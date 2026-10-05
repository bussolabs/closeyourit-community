# frozen_string_literal: true

require "rails_helper"

# CYRA-364 — le voci del campo «Ticket collegato». Il codice del ticket non è una colonna
# (project.key + numero): la prova che conta è che cercarlo lo trovi comunque.
RSpec.describe Ticketing::LinkableTickets do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:, key: "CYRA") }
  let(:altro) { create(:project, organization:, key: "PFCL") }
  let(:scope) { Ticketing::Ticket.where(project_id: [ project.id, altro.id ]) }

  def ticket(title, project_ref = project, updated: Time.current)
    create(:ticket, organization:, project: project_ref, title:).tap do |record|
      record.update_column(:updated_at, updated)
    end
  end

  it "senza query dà i toccati di recente, dal più fresco" do
    ticket("Vecchio", project, updated: 3.days.ago)
    fresco = ticket("Fresco", project, updated: 1.minute.ago)

    expect(described_class.call(scope:).first).to eq(fresco)
  end

  it "trova per parola del titolo" do
    cercato = ticket("Il campo dei ticket collegati è lento")
    ticket("Tutt'altro argomento")

    expect(described_class.call(scope:, query: "collegati")).to contain_exactly(cercato)
  end

  it "trova per codice intero, che nel database non esiste come colonna" do
    cercato = ticket("Per codice")
    altrove = ticket("Stesso numero, altro progetto", altro)

    risultati = described_class.call(scope:, query: cercato.code)

    expect(risultati).to include(cercato)
    expect(risultati).not_to include(altrove) if altrove.number != cercato.number
  end

  it "trova per solo numero, in qualunque progetto" do
    cercato = ticket("Solo numero")

    expect(described_class.call(scope:, query: cercato.number.to_s)).to include(cercato)
  end

  it "il codice si scrive anche senza trattino e in minuscolo" do
    cercato = ticket("Codice sciolto")

    expect(described_class.call(scope:, query: "cyra #{cercato.number}")).to include(cercato)
  end

  it "restringe ai progetti del contesto" do
    dentro = ticket("Dentro il contesto")
    fuori = ticket("Fuori dal contesto", altro)

    risultati = described_class.call(scope:, project_ids: [ project.id ])

    expect(risultati).to include(dentro)
    expect(risultati).not_to include(fuori)
  end

  it "con all: true il contesto non restringe più niente" do
    ticket("Dentro il contesto")
    fuori = ticket("Fuori dal contesto", altro)

    expect(described_class.call(scope:, project_ids: [ project.id ], all: true)).to include(fuori)
  end

  # Un contesto che non risolve nessun progetto è un contesto assente: restringere a zero darebbe
  # un campo sempre vuoto, che chi lo usa legge come rotto.
  it "un contesto vuoto non azzera i risultati" do
    dentro = ticket("C'è comunque")

    expect(described_class.call(scope:, project_ids: [])).to include(dentro)
  end

  it "non restituisce più voci del limite" do
    allow_n_plus_one { create_list(:ticket, 10, organization:, project:) }

    expect(described_class.call(scope:).size).to eq(described_class::LIMIT)
  end

  it "i caratteri jolly di LIKE sono testo cercato, non sintassi" do
    ticket("Titolo normale")

    expect(described_class.call(scope:, query: "%")).to be_empty
  end
end
