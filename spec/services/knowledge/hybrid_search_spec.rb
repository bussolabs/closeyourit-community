# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::HybridSearch do
  let(:client) { instance_double(Ai::Embedding::Client) }
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }

  def embedded_page(index, title:)
    create(:knowledge_page, organization: org, project: project, title: title).tap do |page|
      page.update_columns(embedding: basis_vector(index), embedding_checksum: "x",
                          embedded_at: Time.current, embedding_version: Ai::Constants::EMBEDDING_VERSION)
    end
  end

  it "senza query non cerca niente e lascia la scope com'era" do
    create(:knowledge_page, organization: org, project: project)

    outcome = described_class.call(scope: Knowledge::Page.all, query: "  ", client: client)

    expect(outcome.mode).to be_nil
    expect(outcome.scope.to_sql).to eq(Knowledge::Page.all.to_sql)
  end

  it "«parole esatte» chieste: solo testuale, nessuna chiamata al servizio" do
    match = create(:knowledge_page, organization: org, project: project, title: "Backup del database")
    create(:knowledge_page, organization: org, project: project, title: "Palette colori")

    outcome = described_class.call(scope: Knowledge::Page.all, query: "backup", semantic: false, client: client)

    expect(outcome.mode).to eq(:like)
    expect(outcome.scope.pluck(:id)).to eq([ match.id ])
  end

  it "servizio embedding giù: degrada al testuale, mai un errore" do
    match = create(:knowledge_page, organization: org, project: project, title: "Backup del database")
    allow(client).to receive(:embed).and_raise(Ai::Embedding::Client::Error.new("giù", code: "R502-AI-001"))

    outcome = described_class.call(scope: Knowledge::Page.all, query: "backup", client: client)

    expect(outcome.mode).to eq(:like)
    expect(outcome.scope.pluck(:id)).to eq([ match.id ])
  end

  # Il cuore di CYRA-769: una pagina senza embedding esiste per davvero — la proposta in revisione
  # non ne ha mai uno — e il solo ramo semantico la scarterebbe in silenzio.
  it "prima la pertinenza semantica, poi i match testuali senza embedding" do
    near = embedded_page(0, title: "Backup del database")
    senza_embedding = create(:knowledge_page, :in_review, organization: org, project: project,
                                                          title: "Backup: la trappola")
    allow(client).to receive(:embed).and_return([ basis_vector(0) ])
    allow(client).to receive(:rerank).and_return([ { index: 0, score: 0.9 } ])

    outcome = described_class.call(scope: Knowledge::Page.all, query: "backup", client: client)

    expect(outcome.mode).to eq(:semantic)
    expect(outcome.scope.pluck(:id)).to eq([ near.id, senza_embedding.id ])
  end

  it "una pagina già trovata dal significato non si ripete in coda" do
    near = embedded_page(0, title: "Backup del database")
    allow(client).to receive(:embed).and_return([ basis_vector(0) ])
    allow(client).to receive(:rerank).and_return([ { index: 0, score: 0.9 } ])

    outcome = described_class.call(scope: Knowledge::Page.all, query: "backup", client: client)

    expect(outcome.scope.pluck(:id)).to eq([ near.id ])
  end

  it "nessuna corrispondenza: lista vuota, non l'archivio intero" do
    create(:knowledge_page, organization: org, project: project, title: "Palette colori")
    allow(client).to receive(:embed).and_return([ basis_vector(0) ])

    outcome = described_class.call(scope: Knowledge::Page.all, query: "backup", client: client)

    expect(outcome.mode).to eq(:semantic)
    expect(outcome.scope).to be_empty
  end

  # La coda testuale decide anche la paginazione: senza un ordine esplicito quale pagina mostra
  # cosa lo sceglie il piano, e fra pagina 1 e pagina 2 (due query distinte) una riga può ripetersi
  # o sparire. L'ordine è quello dell'elenco: la più recente prima.
  it "la coda testuale esce nell'ordine dell'elenco, non in quello che capita" do
    vecchia = create(:knowledge_page, :in_review, organization: org, project: project, title: "Backup vecchio")
    media = create(:knowledge_page, :in_review, organization: org, project: project, title: "Backup medio")
    recente = create(:knowledge_page, :in_review, organization: org, project: project, title: "Backup recente")
    vecchia.update_columns(updated_at: 3.days.ago)
    media.update_columns(updated_at: 2.days.ago)
    recente.update_columns(updated_at: 1.day.ago)
    allow(client).to receive(:embed).and_return([ basis_vector(0) ])

    outcome = described_class.call(scope: Knowledge::Page.all.ordered, query: "backup", client: client)

    expect(outcome.scope.pluck(:id)).to eq([ recente.id, media.id, vecchia.id ])
  end

  # `pluck` su una relation con `includes` costruisce i LEFT OUTER JOIN del preload: senza toglierli
  # una pagina collegata a 2 progetti entra DUE volte nella lista che ordina i risultati.
  it "una pagina collegata a più progetti entra una volta sola nella lista che ordina" do
    multi = create(:knowledge_page, :in_review, organization: org, project: project, title: "Backup del database")
    multi.projects << create(:project, organization: org)
    multi.groups << create(:group, organization: org)
    singola = create(:knowledge_page, :in_review, organization: org, project: project, title: "Backup notturno")
    allow(client).to receive(:embed).and_return([ basis_vector(0) ])

    scope = Knowledge::Page.all.includes(:projects, :groups, :created_by).ordered
    outcome = described_class.call(scope: scope, query: "backup", client: client)

    expect(outcome.scope.to_a.map(&:id)).to contain_exactly(multi.id, singola.id)
    # Gli id entrano nell'IN e nell'ORDER BY CASE di in_order_of: chi ha più scope non deve
    # comparirci più volte di chi ne ha uno solo — è lì che i doppioni del preload si vedrebbero.
    sql = outcome.scope.to_sql
    expect(sql.scan(multi.id).size).to eq(sql.scan(singola.id).size)
  end

  # Allargare gli stati non allarga i permessi: entrambi i rami cercano DENTRO la scope ricevuta.
  it "la coda testuale non esce mai dalla scope che le è stata data" do
    fuori = create(:knowledge_page, :in_review, organization: org, project: create(:project, organization: org),
                                                title: "Backup del database")
    dentro = create(:knowledge_page, :in_review, organization: org, project: project, title: "Backup notturno")
    allow(client).to receive(:embed).and_return([ basis_vector(0) ])

    outcome = described_class.call(scope: Knowledge::Page.where(id: dentro.id), query: "backup", client: client)

    ids = outcome.scope.pluck(:id)
    expect(ids).to eq([ dentro.id ])
    expect(ids).not_to include(fuori.id)
  end
end
