# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::FindRelatedPages do
  let(:client) { instance_double(Ai::Embedding::Client) }
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }

  def embedded_page(index, project:, title: "Pagina", body: "Testo di prova.")
    create(:knowledge_page, organization: org, project: project, title: title, body: body).tap do |page|
      page.update_columns(embedding: basis_vector(index), embedding_checksum: "x",
                          embedded_at: Time.current, embedding_version: Ai::Constants::EMBEDDING_VERSION)
    end
  end

  def embedded_ticket(title: "Il login non funziona", index: 0)
    create(:ticket, organization: org, project: project, title: title).tap do |ticket|
      ticket.update_columns(embedding: basis_vector(index), embedding_version: Ai::Constants::EMBEDDING_VERSION)
    end
  end

  it "usa l'embedding persistito del ticket (nessuna chiamata al servizio) e filtra per progetto" do
    ticket = embedded_ticket
    near = embedded_page(0, project: project, title: "Guida al login")
    other_project = create(:project, organization: org)
    _foreign = embedded_page(0, project: other_project, title: "Guida al login altrove")

    allow(Embeddings::EmbedText).to receive(:call)
    result = described_class.call(record: ticket, client: client)

    expect(result).to be_ok
    expect(result.value.map(&:page)).to eq([ near ])
    expect(Embeddings::EmbedText).not_to have_received(:call)
  end

  it "non porta nel pannello le proposte in revisione o scartate (CYRA-298)" do
    ticket = embedded_ticket
    pubblicata = embedded_page(0, project: project, title: "Guida al login")
    proposta = embedded_page(0, project: project, title: "Proposta sul login")
    proposta.update_columns(status: Knowledge::Page.statuses[:in_review])
    scartata = embedded_page(0, project: project, title: "Scartata sul login")
    scartata.update_columns(status: Knowledge::Page.statuses[:rejected])

    result = described_class.call(record: ticket, client: client)

    expect(result.value.map(&:page)).to eq([ pubblicata ])
  end

  it "record senza embedding → embedda al volo il testo canonico" do
    ticket = create(:ticket, organization: org, project: project, title: "Il login non funziona")
    near = embedded_page(0, project: project, title: "Guida al login")
    allow(Embeddings::EmbedText).to receive(:call).and_return(Result.ok(basis_vector(0)))

    result = described_class.call(record: ticket, client: client)
    expect(result.value.map(&:page)).to eq([ near ])
    expect(Embeddings::EmbedText).to have_received(:call)
      .with(text: Ticketing::EmbeddingText.call(ticket: ticket), client: client)
  end

  it "funziona anche per un gruppo errori e scarta i lontani (soglia)" do
    group = create(:error_group, project: project, title: "Errore di login")
    group.update_columns(embedding: basis_vector(0), embedding_version: Ai::Constants::EMBEDDING_VERSION)
    near = embedded_page(0, project: project, title: "Runbook errori login")
    _far = embedded_page(1, project: project, title: "Runbook errori login lontano")

    result = described_class.call(record: group, client: client)
    expect(result.value.map(&:page)).to eq([ near ])
  end

  it "servizio giù su record non embeddato → err (il pannello mostra il vuoto)" do
    ticket = create(:ticket, organization: org, project: project)
    allow(Embeddings::EmbedText).to receive(:call)
      .and_return(Result.err(AppError.new("giù", code: "R502-AI-001")))

    result = described_class.call(record: ticket, client: client)
    expect(result).to be_err
  end

  it "record-sorgente con embedding di versione superata → vuoto, senza mescolare (CYRA-168)" do
    ticket = create(:ticket, organization: org, project: project, title: "Il login non funziona")
    ticket.update_columns(embedding: basis_vector(0), embedding_version: "qwen3-emb-0.6b-1024-v0")
    embedded_page(0, project: project, title: "Guida al login") # sarebbe un vicino, ma la sorgente è stale
    allow(Embeddings::EmbedText).to receive(:call)

    result = described_class.call(record: ticket, client: client)

    expect(result).to be_ok
    expect(result.value).to eq([])
    expect(Embeddings::EmbedText).not_to have_received(:call) # non embedda nemmeno il testo canonico
  end

  # CYRA-414 — il pannello proponeva materiale che non c'entrava e cinque voci quasi identiche in
  # una colonna già affollata: ora ogni riga deve saper dire perché è lì, e le righe sono al più tre.
  describe "pertinenza dimostrabile (CYRA-414)" do
    it "scarta il vicino che non ha nulla in comune col ticket" do
      ticket = embedded_ticket(title: "Rifacimento della raccolta dati")
      _fuori_tema = embedded_page(0, project: project, title: "Backup del database su spazio dedicato",
                                     body: "Conservazione e ripristino delle copie.")

      result = described_class.call(record: ticket, client: client)

      expect(result.value).to eq([])
    end

    it "ogni riga porta il motivo del collegamento" do
      ticket = embedded_ticket(title: "Il login non funziona")
      embedded_page(0, project: project, title: "Runbook del login")

      row = described_class.call(record: ticket, client: client).value.first

      expect(row.reason.terms).to eq([ "login" ])
    end

    it "mostra al massimo tre pagine, le più vicine" do
      ticket = embedded_ticket(title: "Il login non funziona")
      pages = 5.times.map do |i|
        create(:knowledge_page, organization: org, project: project, title: "Guida al login numero #{i}")
          .tap do |page|
            page.update_columns(embedding: blend_vector(0, 500 + i, weight: 0.99 - (i * 0.01)),
                                embedding_checksum: "x", embedded_at: Time.current,
                                embedding_version: Ai::Constants::EMBEDDING_VERSION)
          end
      end

      result = described_class.call(record: ticket, client: client)

      expect(result.value.map(&:page)).to eq(pages.first(3))
    end

    it "i vicini senza motivo non rubano il posto a quelli che ce l'hanno" do
      ticket = embedded_ticket(title: "Il login non funziona")
      3.times do |i|
        embedded_page(0, project: project, title: "Palette dei colori #{i}", body: "Tinte e contrasti.")
      end
      pertinente = create(:knowledge_page, organization: org, project: project, title: "Runbook del login")
      pertinente.update_columns(embedding: blend_vector(0, 700, weight: 0.9), embedding_checksum: "x",
                                embedded_at: Time.current, embedding_version: Ai::Constants::EMBEDDING_VERSION)

      result = described_class.call(record: ticket, client: client)

      expect(result.value.map(&:page)).to eq([ pertinente ])
    end
  end
end
