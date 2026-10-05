# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ideas::FindSimilarIdeas do
  let(:client) { instance_double(Ai::Embedding::Client) }
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }

  def seeded_idea(index, project: self.project, title: "Idea #{index}", status: :open,
                  version: Ai::Constants::EMBEDDING_VERSION)
    create(:idea, organization: project.organization, project: project, title: title, status: status).tap do |idea|
      idea.update_columns(embedding: basis_vector(index), embedding_checksum: "x",
                          embedded_at: Time.current, embedding_version: version)
    end
  end

  it "ritorna le simili sotto soglia, ordinate per distanza, con neighbor_distance" do
    near = seeded_idea(0)
    seeded_idea(7) # ortogonale → fuori soglia
    allow(client).to receive(:embed).and_return([ blend_vector(0, 1, weight: 0.98) ])

    result = described_class.call(scope: Ideas::Idea.all, text: "idea simile", client: client)

    expect(result).to be_ok
    expect(result.value.map(&:id)).to eq([ near.id ])
    expect(result.value.first.neighbor_distance).to be < described_class::MAX_DISTANCE
  end

  it "cerca cross-progetto dentro la scope (doppioni proposti su un altro progetto)" do
    other_project = create(:project, organization: org)
    twin = seeded_idea(0, project: other_project)
    allow(client).to receive(:embed).and_return([ basis_vector(0) ])

    result = described_class.call(scope: Ideas::Idea.all, text: "x", client: client)

    expect(result.value.map(&:id)).to eq([ twin.id ])
  end

  it "suggerisce anche le idee già convertite o archiviate (è lì che finisce il doppione)" do
    converted = seeded_idea(0, title: "Già diventata un ticket", status: :converted)
    allow(client).to receive(:embed).and_return([ basis_vector(0) ])

    result = described_class.call(scope: Ideas::Idea.all, text: "x", client: client)

    expect(result.value.map(&:id)).to include(converted.id)
  end

  it "esclude le idee embeddate con una versione del modello diversa dalla corrente" do
    current = seeded_idea(0, title: "Versione corrente")
    seeded_idea(0, title: "Versione vecchia", version: "qwen3-emb-0.6b-1024-v0")
    allow(client).to receive(:embed).and_return([ basis_vector(0) ])

    result = described_class.call(scope: Ideas::Idea.all, text: "x", client: client)

    expect(result.value.map(&:id)).to eq([ current.id ])
  end

  it "nessuna simile → Result.ok([])" do
    seeded_idea(7)
    allow(client).to receive(:embed).and_return([ basis_vector(0) ])

    expect(described_class.call(scope: Ideas::Idea.all, text: "x", client: client).value).to eq([])
  end

  it "testo blank → Result.err R422-AI-002 senza chiamare il servizio" do
    expect(client).not_to receive(:embed)

    result = described_class.call(scope: Ideas::Idea.all, text: "  ", client: client)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-AI-002")
  end

  it "servizio giù → Result.err propagato (il chiamante nasconde il pannello)" do
    allow(client).to receive(:embed)
      .and_raise(Ai::Embedding::Client::Error.new("giù", code: "R502-AI-001"))

    result = described_class.call(scope: Ideas::Idea.all, text: "x", client: client)

    expect(result).to be_err
    expect(result.error.code).to eq("R502-AI-001")
  end
end
