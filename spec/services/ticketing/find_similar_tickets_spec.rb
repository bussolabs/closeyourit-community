# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::FindSimilarTickets do
  let(:client) { instance_double(Ai::Embedding::Client) }
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }

  def seeded_ticket(index, project: self.project, title: "Ticket #{index}")
    create(:ticket, organization: project.organization, project: project, title: title).tap do |t|
      t.update_columns(embedding: basis_vector(index), embedding_checksum: "x",
                       embedded_at: Time.current, embedding_version: Ai::Constants::EMBEDDING_VERSION)
    end
  end

  it "ritorna i simili sopra soglia, ordinati per distanza, con la somiglianza in percento" do
    near = seeded_ticket(0)
    seeded_ticket(7) # ortogonale → 0% di somiglianza, fuori soglia
    allow(client).to receive(:embed).and_return([ blend_vector(0, 1, weight: 0.98) ])

    result = described_class.call(scope: Ticketing::Ticket.all, text: "titolo simile", client: client)

    expect(result).to be_ok
    expect(result.value.map { |match| match.ticket.id }).to eq([ near.id ])
    expect(result.value.first.similarity).to eq(98)
  end

  it "usa la soglia richiesta dal chiamante: pannello e confronto guardano lo stesso archivio" do
    seeded_ticket(0)
    allow(client).to receive(:embed).and_return([ blend_vector(0, 1, weight: 0.85) ])
    scope = Ticketing::Ticket.all

    panel = described_class.call(scope: scope, text: "x", client: client,
                                 min_similarity: Ticketing::Constants::DUPLICATE_PANEL_SIMILARITY)
    gate = described_class.call(scope: scope, text: "x", client: client,
                                min_similarity: Ticketing::Constants::DUPLICATE_GATE_SIMILARITY)

    expect(panel.value.map(&:similarity)).to eq([ 85 ])
    expect(gate.value).to eq([])
  end

  it "decide sulla percentuale che si legge, non sul numero grezzo che c'è sotto" do
    # 0,896 di somiglianza si scrive «90%»: se la soglia guardasse la frazione grezza, quel ticket
    # comparirebbe con scritto 90 accanto e verrebbe scartato da una soglia del 90.
    seeded_ticket(0)
    allow(client).to receive(:embed).and_return([ blend_vector(0, 1, weight: 0.896) ])

    result = described_class.call(scope: Ticketing::Ticket.all, text: "x", client: client,
                                  min_similarity: 90)

    expect(result.value.map(&:similarity)).to eq([ 90 ])
  end

  it "cerca dentro la scope che riceve: il filtro di progetto e di stato lo decide il chiamante" do
    other_project = create(:project, organization: org)
    seeded_ticket(0, project: other_project)
    mine = seeded_ticket(0)
    allow(client).to receive(:embed).and_return([ basis_vector(0) ])

    result = described_class.call(scope: Ticketing::Ticket.where(project_id: project.id), text: "x",
                                  client: client)

    expect(result.value.map { |match| match.ticket.id }).to eq([ mine.id ])
  end

  it "nessun simile → Result.ok([])" do
    seeded_ticket(7)
    allow(client).to receive(:embed).and_return([ basis_vector(0) ])

    expect(described_class.call(scope: Ticketing::Ticket.all, text: "x", client: client).value).to eq([])
  end

  it "testo blank → Result.err R422-AI-002 senza chiamare il servizio" do
    expect(client).not_to receive(:embed)

    result = described_class.call(scope: Ticketing::Ticket.all, text: "  ", client: client)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-AI-002")
  end

  it "servizio giù → Result.err propagato" do
    allow(client).to receive(:embed)
      .and_raise(Ai::Embedding::Client::Error.new("giù", code: "R502-AI-001"))

    result = described_class.call(scope: Ticketing::Ticket.all, text: "x", client: client)

    expect(result).to be_err
    expect(result.error.code).to eq("R502-AI-001")
  end
end
