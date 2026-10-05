# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::UpdatePage do
  include ActiveJob::TestHelper

  let(:page) { create(:knowledge_page, title: "Setup", body: "Testo", kind: :note) }
  let(:actor) { create(:account) }

  def embed_jobs_count
    enqueued_jobs.count { |job| job["job_class"] == "Knowledge::EmbedPageJob" }
  end

  it "aggiorna i campi, congela una versione e ri-accoda l'embedding quando cambia il testo" do
    result = nil
    expect do
      result = described_class.call(page: page, params: { title: "Setup ambienti", body: "Testo", kind: "guide" }, actor: actor)
    end.to change { page.versions.count }.by(1)

    expect(result).to be_ok
    expect(page.reload.title).to eq("Setup ambienti")
    expect(page.kind).to eq("guide")
    expect(embed_jobs_count).to eq(1)
  end

  it "la versione congelata rispecchia il nuovo contenuto e l'autore" do
    described_class.call(page: page, params: { title: "Setup ambienti", body: "Nuovo", kind: "guide" }, actor: actor)

    version = page.versions.chronological.last
    expect(version.number).to eq(1)
    expect(version.title).to eq("Setup ambienti")
    expect(version.body).to eq("Nuovo")
    expect(version.kind).to eq("guide")
    expect(version.created_by).to eq(actor)
    expect(version.author_name).to eq(actor.name)
  end

  # CYRA-768 — la via d'uscita naturale: se il testo cambia, il conto riparte da sé. È la conferma
  # «a vuoto» a chiedere una persona, non la riscrittura — il contenuto è nuovo ed è ripassato dal
  # controllo. Vale per qualunque canale, anche automatico.
  describe "data di rilettura" do
    let(:decisione) do
      create(:knowledge_page, :decision, title: "Scelta del proxy", body: "Vecchio testo")
        .tap { |record| record.update_columns(review_after: 1.day.ago) }
    end

    it "riparte quando il testo cambia" do
      freeze_time do
        described_class.call(page: decisione, params: { body: "Testo riscritto da capo" }, actor: actor)

        expect(decisione.reload.review_after).to eq(Knowledge::ReviewSchedule.next_for(kind: :decision))
        expect(decisione).not_to be_needs_review
      end
    end

    it "resta ferma quando cambiano solo i tag" do
      expect { described_class.call(page: decisione, params: { tags: %w[proxy rete] }, actor: actor) }
        .not_to change { decisione.reload.review_after }
    end

    it "segue il nuovo tipo quando la pagina cambia tipo" do
      freeze_time do
        described_class.call(page: decisione, params: { body: "Testo riscritto da capo", kind: "guide" }, actor: actor)

        expect(decisione.reload.review_after).to eq(Knowledge::ReviewSchedule.next_for(kind: :guide))
      end
    end

    it "sparisce quando la pagina diventa una nota" do
      described_class.call(page: decisione, params: { body: "Testo riscritto da capo", kind: "note" }, actor: actor)

      expect(decisione.reload.review_after).to be_nil
    end

    it "non nasce su una proposta ancora in revisione" do
      proposta = create(:knowledge_page, :in_review, :decision, title: "Scelta del proxy", body: "Vecchio testo")

      described_class.call(page: proposta, params: { body: "Testo riscritto da capo" }, actor: actor)

      expect(proposta.reload.review_after).to be_nil
    end
  end

  it "kind assente → mantiene il corrente" do
    described_class.call(page: page, params: { title: "Setup", body: "Testo nuovo", kind: "" }, actor: actor)
    expect(page.reload.kind).to eq("note")
  end

  it "nessuna colonna watched cambiata → nessun re-embed e nessuna versione" do
    result = described_class.call(page: page, params: { title: page.title, body: page.body, kind: page.kind }, actor: actor)
    expect(result).to be_ok
    expect(embed_jobs_count).to eq(0)
    expect(page.versions.count).to eq(0)
  end

  it "pagina invalida → err R422-KNOWLEDGE-002 senza job né versione" do
    result = described_class.call(page: page, params: { title: "", body: "" }, actor: actor)
    expect(result).to be_err
    expect(result.error.code).to eq("R422-KNOWLEDGE-002")
    expect(embed_jobs_count).to eq(0)
    expect(page.versions.count).to eq(0)
  end

  it "aggiornare la sezione tecnica congela una versione e ri-embedda (tech_spec è watched)" do
    result = nil
    expect do
      result = described_class.call(
        page: page,
        params: { title: page.title, body: page.body, kind: page.kind, tech_spec: "Indice HNSW su vector(1024)." },
        actor: actor
      )
    end.to change { page.versions.count }.by(1)

    expect(result).to be_ok
    expect(page.reload.tech_spec).to eq("Indice HNSW su vector(1024).")
    expect(embed_jobs_count).to eq(1)
    expect(page.versions.chronological.last.tech_spec).to eq("Indice HNSW su vector(1024).")
  end

  it "update parziale (solo body, via CLI) non azzera la sezione tecnica esistente" do
    page.update!(tech_spec: "Dettagli da preservare.")

    result = described_class.call(page: page, params: { body: "Solo corpo nuovo." }, actor: actor)

    expect(result).to be_ok
    expect(page.reload.body).to eq("Solo corpo nuovo.")
    expect(page.tech_spec).to eq("Dettagli da preservare.")
    expect(page.title).to eq("Setup")
  end

  describe "collegamenti wikilink" do
    let(:target) do
      create(:knowledge_page, organization: page.project.organization, project: page.project, title: "Deploy Kamal")
    end

    it "riallinea il grafo quando cambia il corpo" do
      target
      described_class.call(page: page, params: { body: "Segue [[Deploy Kamal]]." }, actor: actor)
      expect(page.links.reload.map(&:related)).to eq([ target ])

      described_class.call(page: page, params: { body: "Nessun riferimento." }, actor: actor)
      expect(page.links.reload).to be_empty
    end

    it "non tocca il grafo quando cambia solo il titolo" do
      target
      described_class.call(page: page, params: { body: "Segue [[Deploy Kamal]]." }, actor: actor)
      link = page.links.reload.sole

      described_class.call(page: page, params: { title: "Rollback" }, actor: actor)

      expect(page.links.reload.map(&:id)).to eq([ link.id ])
    end
  end

  describe "permesso sui progetti/gruppi aggiunti (CYRA-174)" do
    let(:org) { create(:organization) }
    let(:project_a) { create(:project, organization: org) }
    let(:project_b) { create(:project, organization: org) }
    let(:author) { create(:account).tap { |a| create(:membership, account: a, organization: org, role: :member) } }
    let(:editor) { create(:account).tap { |a| create(:membership, account: a, organization: org, role: :member) } }
    let(:shared_page) { create(:knowledge_page, organization: org, project: project_a, created_by: author) }

    before do
      create(:project_membership, account: editor, project: project_a)
      create(:project_membership, account: editor, project: project_b)
    end

    it "un editor NON autore senza knowledge.edit sul progetto aggiunto → R403-KNOWLEDGE-002" do
      result = described_class.call(page: shared_page,
                                    params: { project_ids: [ project_a.id, project_b.id ] }, actor: editor)

      expect(result).to be_err
      expect(result.error.code).to eq("R403-KNOWLEDGE-002")
      expect(shared_page.reload.projects).to contain_exactly(project_a)
    end

    it "con knowledge.edit sul progetto aggiunto, il collegamento passa" do
      create(:account_permission, account: editor, organization: org, permission_key: "knowledge.edit", effect: :allow)

      result = described_class.call(page: shared_page,
                                    params: { project_ids: [ project_a.id, project_b.id ] }, actor: editor)

      expect(result).to be_ok
      expect(shared_page.reload.projects).to contain_exactly(project_a, project_b)
    end

    it "l'autore aggiunge un progetto visibile alla propria pagina senza knowledge.edit (bypass)" do
      create(:project_membership, account: author, project: project_a)
      create(:project_membership, account: author, project: project_b)

      result = described_class.call(page: shared_page,
                                    params: { project_ids: [ project_a.id, project_b.id ] }, actor: author)

      expect(result).to be_ok
      expect(shared_page.reload.projects).to contain_exactly(project_a, project_b)
    end

    it "se il contenuto è invalido NON muta lo scope (apply_scope dopo il save)" do
      create(:project_membership, account: author, project: project_a)
      create(:project_membership, account: author, project: project_b)

      result = described_class.call(page: shared_page,
                                    params: { body: "", project_ids: [ project_a.id, project_b.id ] }, actor: author)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-KNOWLEDGE-002")
      # Lo scope resta quello originale: la validazione fallita non deve aver toccato i join.
      expect(shared_page.reload.projects).to contain_exactly(project_a)
    end
  end

  # CYRA-419 — «Il segno resta finché una persona non cambia la pagina davvero: correggere una
  # virgola non la rende sua». La soglia è Knowledge::SubstantiveEdit.
  describe "quando decade il segno «scritta da un assistente»" do
    let(:testo) { (1..80).map { |number| "parola#{number}" }.join(" ") }
    let(:pagina_da_assistente) do
      create(:knowledge_page, :written_by_agent, title: "Deploy", body: testo)
    end

    it "una persona che riscrive il testo diventa l'autore e il segno decade" do
      riscritto = testo.split.each_with_index.map { |parola, indice| indice.even? ? "nuova#{indice}" : parola }.join(" ")

      result = described_class.call(page: pagina_da_assistente, params: { body: riscritto }, actor: actor, authored_by: :human)

      expect(result).to be_ok
      expect(pagina_da_assistente.reload).not_to be_written_by_agent
      expect(pagina_da_assistente.author_origin).to be_nil
    end

    it "una persona che corregge una virgola non fa decadere il segno" do
      result = described_class.call(page: pagina_da_assistente, params: { body: "#{testo}." }, actor: actor, authored_by: :human)

      expect(result).to be_ok
      expect(pagina_da_assistente.reload).to be_written_by_agent
      expect(pagina_da_assistente.author_origin).to eq("kb-inbox")
    end

    it "cambiare solo i tag non tocca il segno, per quanto sia un salvataggio" do
      described_class.call(page: pagina_da_assistente, params: { tags: %w[kamal deploy] }, actor: actor, authored_by: :human)

      expect(pagina_da_assistente.reload).to be_written_by_agent
      expect(pagina_da_assistente.tags).to eq(%w[kamal deploy])
    end

    it "un assistente che riscrive la pagina di una persona la marca come propria" do
      pagina_umana = create(:knowledge_page, :written_by_human, title: "Deploy", body: testo)
      riscritto = (1..80).map { |number| "altra#{number}" }.join(" ")

      described_class.call(page: pagina_umana, params: { body: riscritto }, actor: actor,
                           authored_by: :agent, author_origin: "cyi-cli")

      expect(pagina_umana.reload).to be_written_by_agent
      expect(pagina_umana.author_origin).to eq("cyi-cli")
    end

    it "ripristinare una versione precedente non riscrive niente: il segno resta" do
      versione = Knowledge::RecordVersion.call(page: pagina_da_assistente, author: actor)
      described_class.call(page: pagina_da_assistente, params: { body: "#{testo} coda diversa aggiunta a mano dal canale" },
                           actor: actor, authored_by: :human)

      Knowledge::RestoreVersion.call(page: pagina_da_assistente.reload, version: versione, actor: actor)

      expect(pagina_da_assistente.reload).to be_written_by_agent
    end
  end

  describe "permesso sui GRUPPI aggiunti, anche vuoti (CYRA-177)" do
    let(:org) { create(:organization) }
    let(:project_a) { create(:project, organization: org) }
    let(:author) { create(:account).tap { |a| create(:membership, account: a, organization: org, role: :member) } }
    let(:editor) { create(:account).tap { |a| create(:membership, account: a, organization: org, role: :member) } }
    let(:empty_group) { create(:group, organization: org) }
    let(:shared_page) { create(:knowledge_page, organization: org, project: project_a, created_by: author) }

    it "un editor non autore che collega un gruppo vuoto senza gestirlo → R403-KNOWLEDGE-002" do
      create(:group_membership, account: editor, group: empty_group) # lo VEDE (anti-BOLA), ma non lo gestisce

      result = described_class.call(page: shared_page, params: { group_ids: [ empty_group.id ] }, actor: editor)

      expect(result).to be_err
      expect(result.error.code).to eq("R403-KNOWLEDGE-002")
      expect(shared_page.reload.groups).to be_empty
    end

    it "con knowledge.edit che copre il gruppo, il collegamento passa" do
      create(:group_membership, account: editor, group: empty_group)
      create(:account_permission, account: editor, organization: org, permission_key: "knowledge.edit", effect: :allow)

      result = described_class.call(page: shared_page, params: { group_ids: [ empty_group.id ] }, actor: editor)

      expect(result).to be_ok
      expect(shared_page.reload.groups).to contain_exactly(empty_group)
    end

    it "l'autore collega un gruppo vuoto alla propria pagina senza permessi extra" do
      create(:group_membership, account: author, group: empty_group)

      result = described_class.call(page: shared_page, params: { group_ids: [ empty_group.id ] }, actor: author)

      expect(result).to be_ok
      expect(shared_page.reload.groups).to contain_exactly(empty_group)
    end
  end
end

# CYRA-764 — il revisore giudica il testo RISULTANTE, e solo quando il significato cambia.
RSpec.describe Knowledge::UpdatePage, "revisore automatico", knowledge_review: true do
  let(:page) { create(:knowledge_page, title: "Rails — x", body: "Formato: troubleshooting", tech_spec: "dettaglio", kind: :note, tags: %w[rails x]) }
  let(:actor) { create(:account) }
  let(:rejected) do
    Knowledge::Review::Verdict.new(format: "troubleshooting", verdict: "reject", suggested_kind: "note", suggested_title: nil,
                                   split_suggestion: [], duplicate_of: nil, model: "qwen",
                                   violations: [ Knowledge::Review::Violation.new(code: "K04", message: "per ora") ])
  end

  it "solo i tag cambiano: solo le regole meccaniche, senza modello" do
    allow(Knowledge::ReviewPage).to receive(:call).and_return(Result.ok(nil))

    expect(described_class.call(page: page, params: { tags: %w[rails cache] }, actor: actor)).to be_ok
    expect(Knowledge::ReviewPage).to have_received(:call).with(hash_including(tags: %w[rails cache], precheck_only: true))
  end

  it "niente cambia: nessuna chiamata al revisore" do
    allow(Knowledge::ReviewPage).to receive(:call)

    described_class.call(page: page, params: { title: page.title, tags: page.tags }, actor: actor)
    expect(Knowledge::ReviewPage).not_to have_received(:call)
  end

  it "un update parziale (solo body) passa al revisore titolo e parte tecnica persistiti" do
    allow(Knowledge::ReviewPage).to receive(:call).and_return(Result.ok(nil))

    described_class.call(page: page, params: { body: "Formato: troubleshooting\nnuovo" }, actor: actor)
    expect(Knowledge::ReviewPage).to have_received(:call)
      .with(hash_including(title: "Rails — x", body: "Formato: troubleshooting\nnuovo", tech_spec: "dettaglio", kind: "note",
                           tags: %w[rails x], exclude_page_id: page.id))
  end

  it "rifiutata: la pagina resta com'era nel database, ma in memoria porta le modifiche per il form" do
    allow(Knowledge::ReviewPage).to receive(:call).and_return(Result.ok(rejected))

    result = described_class.call(page: page, params: { body: "Formato: troubleshooting\nper ora" }, actor: actor)
    expect(result.error.code).to eq("R422-KNOWLEDGE-013")
    expect(page.body).to eq("Formato: troubleshooting\nper ora")
    expect(page.reload.body).to eq("Formato: troubleshooting")
    expect(page.versions.count).to eq(0)
  end

  it "revisore spento e testo cambiato: il verdetto di prima si azzera, parlava di un altro testo" do
    page.update_columns(ai_review_verdict: 0, ai_review_format: "troubleshooting", ai_reviewed_at: Time.current, ai_review_model: "q")
    allow(Knowledge::ReviewPage).to receive(:call).and_return(Result.ok(nil))

    described_class.call(page: page, params: { body: "Formato: troubleshooting\nnuovo" }, actor: actor)
    expect(page.reload.ai_review_verdict).to be_nil
    expect(page.ai_reviewed_at).to be_nil
  end

  it "solo tag: il verdetto sul testo resta" do
    page.update_columns(ai_review_verdict: 0, ai_review_format: "troubleshooting", ai_reviewed_at: Time.current)
    allow(Knowledge::ReviewPage).to receive(:call).and_return(Result.ok(nil))

    described_class.call(page: page, params: { tags: %w[rails cache] }, actor: actor)
    expect(page.reload).to be_ai_review_accepted
  end
end
