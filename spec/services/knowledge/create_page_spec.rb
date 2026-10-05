# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::CreatePage do
  include ActiveJob::TestHelper

  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:author) { create(:account) }
  let(:owner) { create(:account) }

  before do
    create(:membership, account: author, organization: org, role: :member)
    create(:project_membership, account: author, project: project)
    create(:membership, account: owner, organization: org, role: :owner)
  end

  def call_service(actor: author, **params)
    described_class.call(organization: org, author: actor, params: params)
  end

  it "crea la pagina (autore = created_by, kind default note) e accoda l'embedding" do
    result = call_service(project_ids: [ project.id ], title: "Setup ambienti", body: "Vault ovunque.")

    expect(result).to be_ok
    page = result.value
    expect(page.created_by).to eq(author)
    expect(page.kind).to eq("note")
    expect(page.projects).to contain_exactly(project)
    embed_jobs = enqueued_jobs.select { |job| job["job_class"] == "Knowledge::EmbedPageJob" }
    expect(embed_jobs.map { |job| job["arguments"].first["page_id"] }).to include(page.id)
  end

  # CYRA-768 — una pagina scritta a mano dal web nasce già pubblicata: il conto parte da subito,
  # altrimenti resterebbe vera per sempre senza mai passare dalla coda.
  it "mette la data di rilettura a una pagina che nasce pubblicata" do
    freeze_time do
      result = call_service(project_ids: [ project.id ], title: "Scelta del proxy", body: "Passa da kamal-proxy.", kind: "decision")

      expect(result.value.review_after).to eq(Knowledge::ReviewSchedule.next_for(kind: :decision))
    end
  end

  it "non mette nessuna scadenza a una nota" do
    result = call_service(project_ids: [ project.id ], title: "Appunto", body: "Poi vediamo.")

    expect(result.value.review_after).to be_nil
  end

  it "lascia senza data una proposta ancora in revisione: il conto parte all'accettazione" do
    result = call_service(project_ids: [ project.id ], title: "Scelta del proxy", body: "Passa da kamal-proxy.",
                          kind: "decision", in_review: true, tech_spec: "kamal-proxy, healthcheck su /up/database.")

    expect(result.value).to be_status_in_review
    expect(result.value.review_after).to be_nil
  end

  it "congela la versione 1 con il contenuto iniziale e l'autore" do
    result = call_service(project_ids: [ project.id ], title: "Setup ambienti", body: "Vault ovunque.", kind: "guide")
    page = result.value

    expect(page.versions.count).to eq(1)
    version = page.versions.first
    expect(version.number).to eq(1)
    expect(version.title).to eq("Setup ambienti")
    expect(version.body).to eq("Vault ovunque.")
    expect(version.kind).to eq("guide")
    expect(version.created_by).to eq(author)
    expect(version.author_name).to eq(author.name)
    expect(version.organization).to eq(org)
  end

  it "accetta il kind esplicito" do
    result = call_service(project_ids: [ project.id ], title: "Scelta DB", body: "PostgreSQL.", kind: "decision")
    expect(result.value.kind).to eq("decision")
  end

  it "salva la sezione tecnica e la congela nella versione 1" do
    result = call_service(project_ids: [ project.id ], title: "Setup", body: "Corpo.", tech_spec: "Colonna vector(1024).")

    expect(result).to be_ok
    page = result.value
    expect(page.tech_spec).to eq("Colonna vector(1024).")
    expect(page.versions.first.tech_spec).to eq("Colonna vector(1024).")
  end

  it "collega più progetti e un gruppo visibili" do
    other_project = create(:project, organization: org)
    create(:project_membership, account: author, project: other_project)
    group = create(:group, organization: org)
    create(:group_membership, account: author, group: group)

    result = call_service(project_ids: [ project.id, other_project.id ], group_ids: [ group.id ],
                          title: "Sistema Flutter", body: "Decisioni comuni.")

    expect(result).to be_ok
    expect(result.value.projects).to contain_exactly(project, other_project)
    expect(result.value.groups).to contain_exactly(group)
  end

  it "salva i tag normalizzati (strip/downcase/uniq)" do
    result = call_service(project_ids: [ project.id ], title: "T", body: "B",
                          tags: [ "  Flutter ", "FLUTTER", "flutter-flavor" ])

    expect(result).to be_ok
    expect(result.value.tags).to eq(%w[flutter flutter-flavor])
  end

  it "un progetto non visibile → err R404-KNOWLEDGE-001 (anti-BOLA)" do
    hidden = create(:project, organization: org)
    result = call_service(project_ids: [ hidden.id ], title: "X", body: "Y")
    expect(result).to be_err
    expect(result.error.code).to eq("R404-KNOWLEDGE-001")
  end

  it "pagina generale (zero scope) vietata a un member → R403-KNOWLEDGE-001" do
    result = call_service(project_ids: [], group_ids: [], title: "Generale", body: "Corpo.")
    expect(result).to be_err
    expect(result.error.code).to eq("R403-KNOWLEDGE-001")
  end

  it "pagina generale (zero scope) permessa a un owner (full-access)" do
    result = call_service(actor: owner, project_ids: [], group_ids: [], title: "Generale", body: "Corpo.")
    expect(result).to be_ok
    expect(result.value.projects).to be_empty
    expect(result.value.groups).to be_empty
  end

  it "pagina invalida → err R422-KNOWLEDGE-001 con details e nessun job" do
    result = call_service(project_ids: [ project.id ], title: "", body: "")
    expect(result).to be_err
    expect(result.error.code).to eq("R422-KNOWLEDGE-001")
    expect(result.error.details).to have_key(:title)
    expect(enqueued_jobs.count { |job| job["job_class"] == "Knowledge::EmbedPageJob" }).to eq(0)
    expect(Knowledge::Version.count).to eq(0)
  end

  describe "proposta in revisione (CYRA-298)" do
    it "nasce in revisione con la sua motivazione" do
      result = call_service(project_ids: [ project.id ], title: "Trappola dei worktree",
                            body: "Il database di sviluppo è condiviso.", in_review: true,
                            review_note: "Trappola incontrata oggi, non deducibile dal codice.")

      expect(result).to be_ok
      expect(result.value).to be_status_in_review
      expect(result.value.review_note).to eq("Trappola incontrata oggi, non deducibile dal codice.")
    end

    it "non accoda l'embedding finché non viene accettata" do
      result = call_service(project_ids: [ project.id ], title: "Trappola", body: "Corpo.", in_review: true)

      embed_jobs = enqueued_jobs.select { |job| job["job_class"] == "Knowledge::EmbedPageJob" }
      expect(embed_jobs.map { |job| job["arguments"].first["page_id"] }).not_to include(result.value.id)
    end

    it "resta fuori dalle pagine visibili finché non viene accettata" do
      result = call_service(project_ids: [ project.id ], title: "Trappola", body: "Corpo.", in_review: true)

      visible = Knowledge::Page.visible_to(account: owner, organization: org)
      expect(visible).not_to include(result.value)
    end

    # CYRA-429 — una proposta che arriva con un livello solo porta il difetto già dentro: il livello
    # semplice sarebbe scritto in gergo, e chi revisiona se lo ritrova da riscrivere a mano.
    it "col corpo in gergo e senza parte tecnica viene rimandata indietro" do
      result = call_service(project_ids: [ project.id ], title: "Ingest",
                            body: "Il middleware espone un endpoint webhook per il deploy del backend.",
                            in_review: true)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-KNOWLEDGE-012")
      expect(Knowledge::Page.where(title: "Ingest")).to be_empty
    end

    it "col gergo nella parte tecnica e il corpo in parole semplici passa" do
      result = call_service(project_ids: [ project.id ], title: "Ingest",
                            body: "Come arrivano gli errori delle app dentro CloseYourIt.",
                            tech_spec: "Il middleware espone un endpoint webhook per il deploy del backend.",
                            in_review: true)

      expect(result).to be_ok
      expect(result.value).to be_status_in_review
    end

    it "una proposta in parole semplici passa anche senza parte tecnica" do
      result = call_service(project_ids: [ project.id ], title: "Ferie",
                            body: "Come si chiedono le ferie al proprio responsabile.", in_review: true)

      expect(result).to be_ok
    end

    it "senza il flag nasce pubblicata come sempre" do
      result = call_service(project_ids: [ project.id ], title: "Setup", body: "Corpo.")

      expect(result.value).to be_status_published
      expect(result.value.review_note).to be_nil
    end
  end

  # CYRA-419 — la pagina si portava dietro un nome solo, quello dell'account il cui accesso è stato
  # usato. Chi ha scritto è un'altra cosa e la dichiara il canale.
  describe "chi ha scritto il testo" do
    it "il canale che dichiara un assistente registra origine ed etichetta" do
      result = described_class.call(organization: org, author: author, params: { project_ids: [ project.id ], title: "Trappola", body: "Corpo." },
                                    authored_by: :agent, author_origin: "kb-inbox")

      page = result.value
      expect(page).to be_written_by_agent
      expect(page.author_origin).to eq("kb-inbox")
      expect(page.created_by).to eq(author)
    end

    it "il canale che dichiara una persona non registra nessuna etichetta di canale" do
      result = described_class.call(organization: org, author: author, params: { project_ids: [ project.id ], title: "Setup", body: "Corpo." },
                                    authored_by: :human, author_origin: "kb-inbox")

      expect(result.value).not_to be_written_by_agent
      expect(result.value.author_origin).to be_nil
    end

    it "un canale che non dichiara niente lascia l'origine non registrata, non attribuita a una persona" do
      result = call_service(project_ids: [ project.id ], title: "Setup", body: "Corpo.")

      expect(result.value).to be_author_unregistered
      expect(result.value).not_to be_written_by_agent
    end

    it "un'etichetta lunghissima viene troncata invece di far fallire la scrittura della pagina" do
      result = described_class.call(organization: org, author: author, params: { project_ids: [ project.id ], title: "Trappola", body: "Corpo." },
                                    authored_by: :agent, author_origin: "x" * 500)

      expect(result).to be_ok
      expect(result.value.author_origin.length).to eq(Knowledge::Page::AUTHOR_ORIGIN_MAX_CHARS)
    end
  end

  it "collega le pagine citate con un wikilink nel corpo" do
    target = create(:knowledge_page, organization: org, project: project, title: "Deploy Kamal")

    result = call_service(project_ids: [ project.id ], title: "Rollback", body: "Segue [[Deploy Kamal]].")

    expect(result.value.links.map(&:related)).to eq([ target ])
  end
end

# CYRA-764 — il revisore automatico decide se la pagina entra. Qui è un double: le sue regole hanno
# le loro spec; qui si prova SOLO l'innesto — quando si chiama, cosa ferma, cosa scrive.
RSpec.describe Knowledge::CreatePage, "revisore automatico", knowledge_review: true do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:author) { create(:account) }
  let(:accepted) do
    Knowledge::Review::Verdict.new(format: "troubleshooting", verdict: "accept", violations: [], suggested_kind: "note",
                                   suggested_title: nil, split_suggestion: [], duplicate_of: nil, model: "qwen")
  end
  let(:rejected) do
    Knowledge::Review::Verdict.new(format: "troubleshooting", verdict: "reject", suggested_kind: "note", suggested_title: nil,
                                   split_suggestion: [], duplicate_of: nil, model: "qwen",
                                   violations: [ Knowledge::Review::Violation.new(code: "T01", message: "manca il sintomo") ])
  end

  before do
    create(:membership, account: author, organization: org, role: :member)
    create(:project_membership, account: author, project: project)
  end

  def call_service(**params)
    described_class.call(organization: org, author: author, params: { project_ids: [ project.id ], title: "Rails — x", body: "Formato: troubleshooting", tags: %w[rails x] }.merge(params))
  end

  it "accettata: la pagina nasce con il verdetto sulle sue colonne" do
    allow(Knowledge::ReviewPage).to receive(:call).and_return(Result.ok(accepted))

    page = call_service.value
    expect(page).to be_ai_review_accepted
    expect(page.ai_review_format).to eq("troubleshooting")
    expect(page.ai_review_model).to eq("qwen")
    expect(page.ai_reviewed_at).to be_present
    expect(Knowledge::ReviewPage).to have_received(:call).with(hash_including(title: "Rails — x", kind: :note, tags: %w[rails x], scope: kind_of(ActiveRecord::Relation)))
  end

  it "rifiutata: R422-KNOWLEDGE-013 con le violazioni nei details, e nessuna pagina" do
    allow(Knowledge::ReviewPage).to receive(:call).and_return(Result.ok(rejected))

    result = nil
    expect { result = call_service }.not_to change(Knowledge::Page, :count)
    expect(result.error.code).to eq("R422-KNOWLEDGE-013")
    expect(result.error.status).to eq(:unprocessable_content)
    expect(result.error.message).to include("T01 — manca il sintomo")
    expect(result.error.details[:violations].first).to include(code: "T01")
  end

  it "revisore giù: il 503 risale così com'è e la pagina non entra" do
    allow(Knowledge::ReviewPage).to receive(:call).and_return(Result.err(AppError.new("giù", code: "R503-KNOWLEDGE-001", status: :service_unavailable)))

    result = nil
    expect { result = call_service }.not_to change(Knowledge::Page, :count)
    expect(result.error.code).to eq("R503-KNOWLEDGE-001")
  end

  it "revisore spento: la pagina entra senza verdetto" do
    allow(Knowledge::ReviewPage).to receive(:call).and_return(Result.ok(nil))

    page = call_service.value
    expect(page.ai_review_verdict).to be_nil
    expect(page.ai_reviewed_at).to be_nil
  end
end
