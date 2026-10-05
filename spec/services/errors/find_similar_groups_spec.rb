# frozen_string_literal: true

require "rails_helper"

RSpec.describe Errors::FindSimilarGroups do
  let(:project) { create(:project) }
  let(:group) { create(:error_group, project:, title: "Boom A", culprit: "A#x") }
  let(:client) { instance_double(Ai::Llm::Client) }

  # Con `response_schema` il client restituisce l'Hash gia parsato.
  def cluster_response(ids, reason: "stessa causa")
    { "related_ids" => ids, "reason" => reason }
  end

  it "ritorna lista vuota senza chiamare l'AI quando non ci sono altri gruppi nel progetto" do
    expect(client).not_to receive(:generate_content)

    result = described_class.call(group:, client:)

    expect(result).to be_ok
    expect(result.value.groups).to be_empty
    expect(result.value.reason).to be_nil
  end

  it "ricarica solo i gruppi candidati indicati dall'AI" do
    similar = create(:error_group, project:, title: "Boom A2", culprit: "A#x")
    create(:error_group, project:, title: "Other", culprit: "Z#y")
    allow(client).to receive(:generate_content).and_return(cluster_response([ similar.id ]))

    result = described_class.call(group:, client:)

    expect(result).to be_ok
    expect(result.value.groups.map(&:id)).to contain_exactly(similar.id)
    expect(result.value.reason).to eq("stessa causa")
  end

  it "scarta id allucinati o di altri progetti (anti-leak)" do
    create(:error_group, project:) # un candidato esiste → l'AI viene interpellata
    foreign = create(:error_group, title: "Boom altrove") # progetto diverso
    allow(client).to receive(:generate_content).and_return(
      cluster_response([ foreign.id, "00000000-0000-0000-0000-000000000000" ])
    )

    result = described_class.call(group:, client:)

    expect(result).to be_ok
    expect(result.value.groups).to be_empty
  end

  it "esclude i gruppi già risolti dai candidati" do
    create(:error_group, :resolved, project:, title: "Risolto")
    expect(client).not_to receive(:generate_content) # nessun candidato unresolved → niente chiamata

    result = described_class.call(group:, client:)

    expect(result.value.groups).to be_empty
  end

  it "propaga l'errore del gateway" do
    create(:error_group, project:)
    allow(client).to receive(:generate_content).and_raise(
      Ai::Llm::Client::Error.new("boom", code: "R502-LLM-001")
    )

    result = described_class.call(group:, client:)

    expect(result).to be_err
    expect(result.error.code).to eq("R502-LLM-001")
  end

  # CYRA-765 — i candidati si cercano lo stesso (è lavoro nostro), ma il verdetto lo dà il server AI:
  # senza la sua configurazione l'esito è un errore leggibile, non un 500.
  it "col server AI non configurato dice cosa manca invece di sollevare" do
    create(:error_group, project:) # candidato → il verdetto verrebbe chiesto davvero
    allow(Ai::Llm::Client).to receive(:new).and_raise(KeyError, "AI_API_KEY vuota")

    result = described_class.call(group:)

    expect(result).to be_err
    expect(result.error.code).to eq("R502-LLM-002")
    expect(result.error.status).to eq(:bad_gateway)
  end

  it "err R502-AI-003 se la risposta non è un oggetto" do
    create(:error_group, project:)
    allow(client).to receive(:generate_content).and_return([ "non un raggruppamento" ])

    result = described_class.call(group:, client:)

    expect(result).to be_err
    expect(result.error.code).to eq("R502-AI-003")
  end
  describe "candidati via embeddings (recall semantico)" do
    def embed_group(g, index, version: Ai::Constants::EMBEDDING_VERSION)
      g.update_columns(embedding: basis_vector(index), embedding_checksum: "x",
                       embedded_at: Time.current, embedding_version: version)
      g
    end

    it "candida i vicini semantici (anche rari) ed esclude i lontani, poi vale il verdetto AI" do
      embed_group(group, 0)
      rare_twin = embed_group(create(:error_group, project:, title: "Boom A raro", events_count: 0), 0)
      embed_group(create(:error_group, project:, title: "Altro mondo", events_count: 9_999), 7)
      allow(client).to receive(:generate_content) do |contents:, **|
        # Il candidato lontano non deve nemmeno arrivare al prompt dell'AI.
        expect(contents.first[:parts].first[:text]).not_to include("Altro mondo")
        cluster_response([ rare_twin.id ])
      end

      result = described_class.call(group:, client:)

      expect(result.value.groups.map(&:id)).to eq([ rare_twin.id ])
    end

    it "fallback al ramo frequenza quando il riferimento non è embeddato" do
      frequent = create(:error_group, project:, title: "Frequente", events_count: 100)
      allow(client).to receive(:generate_content).and_return(cluster_response([ frequent.id ]))

      result = described_class.call(group:, client:)

      expect(result.value.groups.map(&:id)).to eq([ frequent.id ])
    end

    it "fallback al ramo frequenza quando nessun candidato è embeddato (backfill in corso)" do
      embed_group(group, 0)
      plain = create(:error_group, project:, title: "Non embeddato", events_count: 5)
      allow(client).to receive(:generate_content).and_return(cluster_response([ plain.id ]))

      result = described_class.call(group:, client:)

      expect(result.value.groups.map(&:id)).to eq([ plain.id ])
    end

    it "riferimento con embedding di versione superata → nessun simile, niente AI (CYRA-168)" do
      embed_group(group, 0, version: "qwen3-emb-0.6b-1024-v0") # riferimento stale (re-embed in corso)
      embed_group(create(:error_group, project:, title: "Gemello", events_count: 1), 0) # candidato corrente
      expect(client).not_to receive(:generate_content)

      result = described_class.call(group:, client:)

      expect(result).to be_ok
      expect(result.value.groups).to be_empty
    end

    it "anti-leak: il gemello semantico di un altro progetto non è mai candidato" do
      embed_group(group, 0)
      embed_group(create(:error_group, project:, title: "Mio", events_count: 1), 0)
      foreign = embed_group(create(:error_group, title: "Gemello altrui"), 0) # altro project
      allow(client).to receive(:generate_content) do |contents:, **|
        expect(contents.first[:parts].first[:text]).not_to include(foreign.id)
        cluster_response([ foreign.id ]) # anche se l'AI lo allucina...
      end

      result = described_class.call(group:, client:)

      expect(result.value.groups.map(&:id)).not_to include(foreign.id) # ...viene scartato
    end
  end
end
