# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Pages::Publish do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:actor) { create(:account) }
  let(:publication_key) { "kb:global:deploy" }
  let(:params) { { title: "Deploy", body: "Versione corrente", kind: "guide" } }

  before do
    create(:membership, account: actor, organization:, role: :member)
    create(:project_membership, account: actor, project:)
    # Il gate del controller garantisce knowledge.edit sul progetto sorgente: il service lo assume,
    # quindi i suoi test lo replicano perché la convergenza/adozione legittima passi (CYRA-177).
    create(:account_permission, account: actor, organization:, permission_key: "knowledge.edit", effect: :allow)
  end

  def publish(overrides = {})
    described_class.call(
      project:, actor:, publication_key:,
      params: params.merge(overrides)
    )
  end

  def embed_jobs_count
    enqueued_jobs.count { |job| job["job_class"] == "Knowledge::EmbedPageJob" }
  end

  context "con 0 pagine legacy omonime" do
    it "crea pagina, chiave e versione in modo atomico" do
      create(:knowledge_page, project:, title: "Deployment", body: "Non è un match esatto")
      result = nil
      expect { result = publish }
        .to change(Knowledge::Page, :count).by(1)
        .and change(Knowledge::Version, :count).by(1)

      expect(result).to be_ok
      expect(result.value.operation).to eq("created")
      expect(result.value.adopted_legacy).to be(false)
      expect(result.value.page).to have_attributes(
        project:, created_by: actor, publication_key:, title: "Deploy", body: "Versione corrente", kind: "guide"
      )
      expect(embed_jobs_count).to eq(1)
    end
  end

  context "con 1 pagina legacy omonima" do
    it "adotta il match case-insensitive/trim preservandone identità e autore" do
      original_author = create(:account)
      legacy = create(:knowledge_page, project:, created_by: original_author, title: "deploy", body: "Vecchia")
      legacy.update_column(:title, "  dEpLoY  ")

      result = nil
      expect { result = publish(title: "  Deploy  ") }.not_to change(Knowledge::Page, :count)

      expect(result).to be_ok
      expect(result.value).to have_attributes(operation: "updated", adopted_legacy: true)
      expect(result.value.page).to eq(legacy)
      expect(legacy.reload).to have_attributes(
        created_by: original_author, publication_key:, title: "Deploy", body: "Versione corrente", kind: "guide"
      )
      expect(legacy.versions.sole.created_by).to eq(actor)
      expect(embed_jobs_count).to eq(1)
    end
  end

  context "con N pagine legacy omonime" do
    it "fallisce chiuso anche quando i match differiscono solo per casing/whitespace" do
      first = create(:knowledge_page, project:, title: "DEPLOY", body: "Uno")
      second = create(:knowledge_page, project:, title: "deploy", body: "Due")
      second.update_column(:title, " deploy ")

      result = publish(title: " Deploy ")

      expect(result).to be_err
      expect(result.error).to have_attributes(code: "R409-KNOWLEDGE-001", status: :conflict)
      expect(first.reload).to have_attributes(publication_key: nil, body: "Uno")
      expect(second.reload).to have_attributes(publication_key: nil, body: "Due")
      expect(embed_jobs_count).to eq(0)
    end
  end

  # CYRA-768 — pubblicare da un repo versionato è un quarto canale di scrittura, accanto a crea,
  # accetta e modifica: senza la data di rilettura qui, il grosso del parco nascerebbe senza scadenza.
  describe "data di rilettura" do
    it "la mette alla pagina creata, coerente col tipo" do
      freeze_time do
        result = publish

        expect(result.value.page.review_after).to eq(Knowledge::ReviewSchedule.next_for(kind: :guide))
      end
    end

    it "non la mette a una nota" do
      expect(publish(kind: "note").value.page.review_after).to be_nil
    end

    it "la fa ripartire quando la pubblicazione porta un testo nuovo" do
      page = publish.value.page
      page.update_columns(review_after: 1.day.ago)

      freeze_time do
        publish(body: "Versione riscritta da capo")

        expect(page.reload.review_after).to eq(Knowledge::ReviewSchedule.next_for(kind: :guide))
      end
    end

    # `cyi kb publish` ripassa sull'intero repo: se ogni giro rinnovasse la data, nessuna pagina
    # scadrebbe mai e la coda resterebbe vuota per sempre.
    it "non la sposta quando la pubblicazione non cambia niente" do
      page = publish.value.page
      scaduta = 1.day.ago.change(usec: 0)
      page.update_columns(review_after: scaduta)

      publish

      expect(page.reload.review_after).to eq(scaduta)
    end
  end

  it "un retry dopo risposta persa restituisce la stessa pagina e aggiorna senza duplicati" do
    first = publish.value

    second = nil
    expect { second = publish(body: "Versione successiva") }.not_to change(Knowledge::Page, :count)

    expect(second).to be_ok
    expect(second.value).to have_attributes(operation: "updated", adopted_legacy: false)
    expect(second.value.page.id).to eq(first.page.id)
    expect(second.value.page.reload.body).to eq("Versione successiva")
    expect(second.value.page.versions.pluck(:number)).to eq([ 1, 2 ])
  end

  it "un retry identico è un no-op senza nuova versione o embedding" do
    page = publish.value.page
    clear_enqueued_jobs

    expect { publish }.not_to change { page.versions.count }
    expect(embed_jobs_count).to eq(0)
  end

  it "recupera il race INSERT dopo un lookup stantio usando il vincolo DB" do
    winner = publish.value
    pages = project.knowledge_pages
    allow(project).to receive(:knowledge_pages).and_return(pages)
    allow(pages).to receive(:find_by).with(publication_key:).and_return(nil)

    loser = nil
    expect { loser = publish }.not_to change(Knowledge::Page, :count)

    expect(loser).to be_ok
    expect(loser.value.page.id).to eq(winner.page.id)
    expect(project.knowledge_pages.where(publication_key:).sole).to eq(winner.page)
  end

  it "non cattura RecordNotUnique estranei all'identità di pubblicazione" do
    unrelated_conflict = ActiveRecord::RecordNotUnique.new("altro vincolo")
    allow(ApplicationRecord).to receive(:transaction).and_raise(unrelated_conflict)

    expect { publish }.to raise_error(unrelated_conflict)
  end

  it "serializza un update concorrente acquisendo il row lock prima del salvataggio" do
    page = publish.value.page
    # L'identità ora è org-scoped: intercetta il lookup su org_pages (Knowledge::Page.where(organization_id:)).
    org_pages = Knowledge::Page.where(organization_id: project.organization_id)
    allow(Knowledge::Page).to receive(:where).and_call_original
    allow(Knowledge::Page).to receive(:where).with(organization_id: project.organization_id).and_return(org_pages)
    allow(org_pages).to receive(:find_by).with(publication_key:).and_return(page)
    expect(page).to receive(:lock!).ordered.and_call_original
    expect(page).to receive(:save!).ordered.and_call_original

    result = publish(body: "Writer concorrente")

    expect(result).to be_ok
    expect(page.reload.body).to eq("Writer concorrente")
  end

  it "converge la stessa publication_key nella stessa org (aggiungendo il progetto), la isola tra organizzazioni" do
    local = publish.value.page
    other_project = create(:project, organization:)
    create(:project_membership, account: actor, project: other_project)
    other_org_project = create(:project)

    # Stessa org, progetto diverso: CONVERGE sulla stessa pagina e vi aggiunge il progetto della route.
    same_org = described_class.call(project: other_project, actor:, publication_key:, params:).value.page
    expect(same_org.id).to eq(local.id)
    expect(local.reload.projects).to include(project, other_project)

    # Altra org: pagina distinta (identità org-scoped).
    foreign_actor = create(:account)
    create(:membership, account: foreign_actor, organization: other_org_project.organization, role: :member)
    create(:project_membership, account: foreign_actor, project: other_org_project)
    other_org = described_class.call(project: other_org_project, actor: foreign_actor, publication_key:, params:).value.page

    expect(other_org.id).not_to eq(local.id)
  end

  it "su validazione fallita esegue rollback dell'adozione legacy" do
    legacy = create(:knowledge_page, project:, title: "Deploy", body: "Vecchia")

    result = publish(body: "")

    expect(result).to be_err
    expect(result.error.code).to eq("R422-KNOWLEDGE-005")
    expect(legacy.reload).to have_attributes(publication_key: nil, body: "Vecchia")
    expect(legacy.versions).to be_empty
    expect(embed_jobs_count).to eq(0)
  end

  it "rifiuta una publication_key vuota senza modificare il database" do
    result = described_class.call(project:, actor:, publication_key: "   ", params:)

    expect(result).to be_err
    expect(result.error.code).to eq("R422-KNOWLEDGE-005")
    expect(result.error.details).to have_key(:publication_key)
    expect(Knowledge::Page.count).to eq(0)
  end

  it "pubblica senza mutazioni chiavi URI-safe ai confini 1 e 255" do
    shortest = described_class.call(project:, actor:, publication_key: "a", params:)
    longest_key = "a" * 255
    longest = described_class.call(
      project:, actor:, publication_key: longest_key,
      params: params.merge(title: "Deploy lungo")
    )

    expect(shortest).to be_ok
    expect(shortest.value.page.publication_key).to eq("a")
    expect(longest).to be_ok
    expect(longest.value.page.publication_key).to eq(longest_key)
  end

  it "rifiuta chiavi non rappresentabili in un path segment prima del lookup legacy" do
    legacy = create(:knowledge_page, project:, title: "Deploy", body: "Vecchia")

    [ "source/deploy", "source?draft=1", "source\ndeploy", "a" * 256 ].each do |invalid_key|
      result = described_class.call(project:, actor:, publication_key: invalid_key, params:)

      expect(result).to be_err
      expect(result.error.code).to eq("R422-KNOWLEDGE-005")
    end
    expect(legacy.reload).to have_attributes(publication_key: nil, body: "Vecchia")
    expect(project.knowledge_pages.count).to eq(1)
  end

  it "rifiuta un kind sconosciuto con errore di validazione invece di sollevare" do
    result = publish(kind: "unknown")

    expect(result).to be_err
    expect(result.error.code).to eq("R422-KNOWLEDGE-005")
    expect(result.error.details).to have_key(:kind)
    expect(Knowledge::Page.count).to eq(0)
  end

  describe "sicurezza dello scope in convergenza (CYRA-177)" do
    it "rifiuta la sovrascrittura di una pagina collegata solo a progetti non visibili" do
      hidden_project = create(:project, organization:)
      hidden = create(:knowledge_page, organization:, project: hidden_project,
                                        created_by: create(:account), title: "Runbook riservato",
                                        body: "Contenuto riservato", publication_key:)

      result = nil
      expect { result = publish }.not_to change(Knowledge::Page, :count)

      expect(result).to be_err
      expect(result.error).to have_attributes(code: "R403-KNOWLEDGE-003", status: :forbidden)
      expect(hidden.reload).to have_attributes(body: "Contenuto riservato")
      expect(hidden.projects).to contain_exactly(hidden_project)
      expect(hidden.versions).to be_empty
      expect(embed_jobs_count).to eq(0)
    end

    it "consente a un editor non autore con knowledge.edit sull'intero scope di convergere" do
      page = publish.value.page
      editor = create(:account)
      create(:membership, account: editor, organization:, role: :member)
      create(:project_membership, account: editor, project:)
      create(:account_permission, account: editor, organization:, permission_key: "knowledge.edit", effect: :allow)

      result = described_class.call(project:, actor: editor, publication_key:,
                                    params: params.merge(body: "Rivisto dall'editor"))

      expect(result).to be_ok
      expect(page.reload.body).to eq("Rivisto dall'editor")
    end

    it "rifiuta l'adozione di una legacy estesa a progetti che l'attore non vede" do
      hidden_project = create(:project, organization:)
      legacy = create(:knowledge_page, organization:, project:, created_by: create(:account),
                                        title: "Deploy", body: "Vecchia")
      legacy.projects << hidden_project

      result = nil
      expect { result = publish(title: "Deploy") }.not_to change(Knowledge::Page, :count)

      expect(result).to be_err
      expect(result.error.code).to eq("R403-KNOWLEDGE-003")
      expect(legacy.reload).to have_attributes(publication_key: nil, body: "Vecchia")
      expect(legacy.versions).to be_empty
    end

    it "rifiuta la sovrascrittura di una pagina org-wide da parte di chi non ha accesso pieno" do
      create(:knowledge_page, :org_wide, organization:, created_by: create(:account),
                                          title: "Globale", body: "Riservata", publication_key:)

      result = nil
      expect { result = publish }.not_to change(Knowledge::Page, :count)

      expect(result).to be_err
      expect(result.error.code).to eq("R403-KNOWLEDGE-003")
    end

    it "rifiuta la sovrascrittura di una pagina collegata solo a un gruppo non gestito" do
      hidden_group = create(:group, organization:)
      page = create(:knowledge_page, :org_wide, organization:, created_by: create(:account),
                                                 title: "Di gruppo", body: "Riservata", publication_key:)
      page.groups << hidden_group

      result = nil
      expect { result = publish }.not_to change(Knowledge::Page, :count)

      expect(result).to be_err
      expect(result.error.code).to eq("R403-KNOWLEDGE-003")
    end
  end

  describe "collegamenti wikilink" do
    let!(:target) { create(:knowledge_page, organization:, project:, title: "Rotazione chiavi") }

    it "collega le pagine citate alla pubblicazione iniziale" do
      page = publish(body: "Presuppone [[Rotazione chiavi]].").value.page

      expect(page.links.map(&:related)).to eq([ target ])
    end

    it "riallinea il grafo quando la ripubblicazione cambia il corpo" do
      page = publish(body: "Presuppone [[Rotazione chiavi]].").value.page

      publish(body: "Non presuppone più nulla.")

      expect(page.links.reload).to be_empty
    end
  end
end

# CYRA-764 — anche la pubblicazione per chiave passa dal revisore, PRIMA della transazione.
RSpec.describe Knowledge::Pages::Publish, "revisore automatico", knowledge_review: true do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:actor) { create(:account) }
  let(:rejected) do
    Knowledge::Review::Verdict.new(format: "unknown", verdict: "reject", suggested_kind: nil, suggested_title: nil,
                                   split_suggestion: [], duplicate_of: nil, model: nil,
                                   violations: [ Knowledge::Review::Violation.new(code: "K01", message: "manca Formato:") ])
  end

  before do
    create(:membership, account: actor, organization:, role: :member)
    create(:project_membership, account: actor, project:)
    create(:account_permission, account: actor, organization:, permission_key: "knowledge.edit", effect: :allow)
  end

  it "rifiutata: nessuna pagina e nessuna transazione aperta" do
    allow(Knowledge::ReviewPage).to receive(:call).and_return(Result.ok(rejected))
    allow(ApplicationRecord).to receive(:transaction).and_call_original

    result = nil
    expect {
      result = described_class.call(project:, actor:, publication_key: "kb:x", params: { title: "Deploy", body: "Passi", kind: "guide", tags: %w[a b] })
    }.not_to change(Knowledge::Page, :count)
    expect(result.error.code).to eq("R422-KNOWLEDGE-013")
    expect(ApplicationRecord).not_to have_received(:transaction)
  end

  it "accettata: la pagina porta il verdetto e i tag della pubblicazione" do
    verdict = Knowledge::Review::Verdict.new(format: "procedure", verdict: "accept", violations: [], suggested_kind: "guide",
                                             suggested_title: nil, split_suggestion: [], duplicate_of: nil, model: "qwen")
    allow(Knowledge::ReviewPage).to receive(:call).and_return(Result.ok(verdict))

    page = described_class.call(project:, actor:, publication_key: "kb:x", params: { title: "Deploy", body: "Passi", kind: "guide", tags: %w[nuxt deploy] }).value.page
    expect(page.ai_review_format).to eq("procedure")
    expect(page.tags).to eq(%w[nuxt deploy])
  end
end
