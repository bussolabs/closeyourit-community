# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::Page, type: :model do
  describe "publication_key" do
    it "è opzionale solo come nil per le pagine legacy e non normalizza identità blank" do
      expect(build(:knowledge_page, publication_key: nil)).to be_valid
      expect(build(:knowledge_page, publication_key: "")).to be_invalid
      expect(build(:knowledge_page, publication_key: "   ")).to be_invalid
    end

    it "delega al DB l'unicità della publication_key per organizzazione" do
      existing = create(:knowledge_page, title: "Runbook", publication_key: "source:runbook")
      # Progetto diverso, STESSA org: l'identità è org-scoped, quindi collide al save.
      other_project = create(:project, organization: existing.organization)
      duplicate_key = build(:knowledge_page, project: other_project, publication_key: "source:runbook")

      expect(described_class.validators_on(:publication_key))
        .not_to include(an_instance_of(ActiveRecord::Validations::UniquenessValidator))
      expect(duplicate_key).to be_valid
      expect { duplicate_key.save! }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "continua a permettere titoli manuali duplicati nello stesso progetto" do
      existing = create(:knowledge_page, title: "Runbook")

      expect { create(:knowledge_page, project: existing.project, title: "Runbook") }
        .to change(described_class, :count).by(1)
    end

    it "isola la publication_key tra organizzazioni ma la congela dopo l'adozione" do
      page = create(:knowledge_page, publication_key: "source:runbook")

      # Altra organizzazione: la stessa chiave è ammessa (identità org-scoped).
      expect { create(:knowledge_page, project: create(:project), publication_key: "source:runbook") }
        .to change(described_class, :count).by(1)

      # Dopo l'adozione la chiave non si può riassegnare.
      page.publication_key = "source:other"
      expect(page).to be_invalid
      expect(page.errors[:publication_key]).to be_present
    end

    it "accetta solo chiavi path-segment URI-safe ai confini 1 e 255" do
      expect(build(:knowledge_page, publication_key: "a")).to be_valid
      expect(build(:knowledge_page, publication_key: "source:runbook_v1.0~draft-2")).to be_valid
      expect(build(:knowledge_page, publication_key: "a" * 255)).to be_valid

      [ "a" * 256, "source/runbook", "source?draft=1", "source\nrunbook", "_source" ].each do |key|
        expect(build(:knowledge_page, publication_key: key)).to be_invalid
      end
    end
  end

  describe "validazioni" do
    it "è valida con project, autore, titolo e corpo" do
      expect(build(:knowledge_page)).to be_valid
    end

    it "richiede titolo e corpo (blank e spazi contano come vuoti)" do
      expect(build(:knowledge_page, title: "   ")).not_to be_valid
      expect(build(:knowledge_page, body: "")).not_to be_valid
      expect(build(:knowledge_page, body: nil)).not_to be_valid
    end

    it "normalizza titolo e corpo (strip)" do
      page = create(:knowledge_page, title: "  Decisione DB  ", body: "  testo  ")
      expect(page.title).to eq("Decisione DB")
      expect(page.body).to eq("testo")
    end
  end

  describe "kind" do
    it "espone note/decision/guide con default note" do
      expect(described_class.new.kind).to eq("note")
      expect(build(:knowledge_page, kind: :decision)).to be_valid
      expect(build(:knowledge_page, kind: :guide)).to be_valid
    end

    it "rifiuta un kind fuori enum" do
      expect { build(:knowledge_page, kind: :poesia) }.to raise_error(ArgumentError)
    end
  end

  describe "tech_spec" do
    it "è opzionale: la pagina è valida anche senza sezione tecnica" do
      expect(build(:knowledge_page, tech_spec: nil)).to be_valid
      expect(build(:knowledge_page)).to be_valid
    end

    it "normalizza a testo strippato, o nil se vuoto/spazi" do
      expect(create(:knowledge_page, tech_spec: "  dettagli  ").tech_spec).to eq("dettagli")
      expect(create(:knowledge_page, tech_spec: "   ").tech_spec).to be_nil
      expect(create(:knowledge_page, tech_spec: nil).tech_spec).to be_nil
    end
  end

  describe "limite di lunghezza" do
    let(:body_max) { Knowledge::Constants::BODY_MAX_CHARS }
    let(:tech_max) { Knowledge::Constants::TECH_SPEC_MAX_CHARS }

    # Pagina già oltre soglia come quelle scritte prima della regola: la si crea aggirando le
    # validazioni, esattamente com'è arrivata in DB ai tempi in cui il tetto non esisteva.
    def legacy_long_page(body_length: body_max + 5_000)
      page = build(:knowledge_page, body: "x" * body_length)
      page.save!(validate: false)
      page
    end

    it "accetta corpo e sezione tecnica esattamente al limite" do
      page = build(:knowledge_page, body: "x" * body_max, tech_spec: "y" * tech_max)
      expect(page).to be_valid
    end

    it "rifiuta il corpo oltre il limite e dice di quanto ha sforato" do
      page = build(:knowledge_page, body: "x" * (body_max + 1))

      expect(page).to be_invalid
      expect(page.errors.details[:body]).to include(hash_including(error: :length_budget_exceeded,
                                                                   count: body_max,
                                                                   actual: body_max + 1))
    end

    it "rifiuta la sezione tecnica oltre il limite" do
      page = build(:knowledge_page, tech_spec: "y" * (tech_max + 1))

      expect(page).to be_invalid
      expect(page.errors.details[:tech_spec]).to include(hash_including(error: :length_budget_exceeded))
    end

    it "rifiuta un titolo oltre i 255 caratteri, ma non intrappola quelli legacy" do
      expect(build(:knowledge_page, title: "t" * 255)).to be_valid
      expect(build(:knowledge_page, title: "t" * 256)).to be_invalid

      legacy = build(:knowledge_page, title: "t" * 300)
      legacy.save!(validate: false)

      legacy.body = "Corpo nuovo" # titolo intoccato → la pagina resta salvabile
      expect(legacy).to be_valid

      legacy.title = "t" * 301
      expect(legacy).to be_invalid
    end

    # Il corpo legacy in DB ha i CRLF di quando non si normalizzava: se il confronto della
    # salvaguardia usasse la sua lunghezza grezza, il testo potrebbe crescere di un carattere per
    # fine-riga senza essere bloccato.
    # Pagina scritta prima della normalizzazione CRLF→LF: in DB il corpo ha ancora i \r. Serve SQL
    # puro — update_columns passa comunque dal type cast dell'attributo, quindi normalizzerebbe.
    # (In lettura invece Rails NON normalizza: il valore torna grezzo, ed è il motivo per cui la
    # salvaguardia deve normalizzare entrambi i lati del confronto.)
    def legacy_crlf_page
      page = create(:knowledge_page)
      described_class.connection.update(
        described_class.sanitize_sql_array(
          [ "UPDATE knowledge_pages SET body = ? WHERE id = ?",
            "#{"x" * (body_max + 500)}#{"\r\n" * 200}z", page.id ]
        )
      )
      page.reload
    end

    it "misura il corpo legacy con CRLF sulla stessa unità del nuovo valore" do
      page = legacy_crlf_page
      normalizzato = described_class.normalize_value_for(:body, page.body).length
      expect(normalizzato).to be < page.body.length # 200 CRLF in meno

      page.body = "y" * (normalizzato + 50) # più corto del grezzo, ma PIÙ LUNGO del legacy vero
      expect(page).to be_invalid

      page.body = "y" * (normalizzato - 50) # si accorcia davvero
      expect(page).to be_valid
    end

    it "lascia salvare una pagina legacy con CRLF senza toccarne il corpo" do
      page = legacy_crlf_page
      page.title = "Titolo nuovo"

      expect(page).to be_valid
    end

    it "conta i fine-riga come li conta il browser (CRLF normalizzato a LF)" do
      al_limite = "x#{"\r\n" * 100}".ljust(body_max + 100, "y") # 4.100 char col CRLF, 4.000 col LF
      page = build(:knowledge_page, body: al_limite)

      expect(page).to be_valid
      expect(page.body.length).to eq(body_max)
      expect(page.body).not_to include("\r")
    end

    it "lascia salvare una pagina già troppo lunga se il corpo si accorcia" do
      page = legacy_long_page
      page.body = "x" * (page.body.length - 1_000)

      expect(page).to be_valid
    end

    it "lascia salvare una pagina già troppo lunga senza toccarne il corpo" do
      page = legacy_long_page
      page.title = "Titolo nuovo"

      expect(page).to be_valid
    end

    it "blocca una pagina già troppo lunga se il corpo cresce ancora" do
      page = legacy_long_page
      page.body = "#{page.body}ancora testo"

      expect(page).to be_invalid
      expect(page.errors.details[:tech_spec]).to be_empty
      expect(page.errors.details[:body]).to include(hash_including(error: :length_budget_exceeded))
    end

    it "pretende comunque il rientro sotto soglia per un campo che era vuoto" do
      page = legacy_long_page
      page.tech_spec = "y" * (tech_max + 1)

      expect(page).to be_invalid
      expect(page.errors.details[:tech_spec]).to include(hash_including(error: :length_budget_exceeded))
    end
  end

  describe "#authored_by?" do
    it "riconosce l'autore e nega gli altri" do
      page = create(:knowledge_page)
      expect(page.authored_by?(page.created_by)).to be(true)
      expect(page.authored_by?(create(:account))).to be(false)
      expect(page.authored_by?(nil)).to be(false)
    end
  end

  describe "scope progetti/gruppi (N:N)" do
    let(:organization) { create(:organization) }

    it "collega più progetti e più gruppi alla stessa pagina" do
      p1 = create(:project, organization: organization)
      p2 = create(:project, organization: organization)
      group = create(:group, organization: organization)
      page = create(:knowledge_page, organization: organization, project: p1)

      page.projects << p2
      page.groups << group

      expect(page.reload.projects).to contain_exactly(p1, p2)
      expect(page.groups).to contain_exactly(group)
    end

    it "ammette una pagina org-wide senza alcun progetto o gruppo (divergenza da Book)" do
      page = build(:knowledge_page, :org_wide, organization: organization)

      expect(page).to be_valid
      expect { page.save! }.to change(described_class, :count).by(1)
      expect(page.reload.projects).to be_empty
      expect(page.groups).to be_empty
    end

    it "rifiuta un progetto di un'altra organizzazione (tenant-integrity)" do
      page = create(:knowledge_page, organization: organization, project: create(:project, organization: organization))
      foreign_project = create(:project) # altra org

      expect { page.projects << foreign_project }.to raise_error(ActiveRecord::RecordInvalid)
    end

    it "richiede l'organizzazione" do
      page = build(:knowledge_page, :org_wide, organization: organization)
      page.organization = nil

      expect(page).to be_invalid
      expect(page.errors[:organization]).to be_present
    end
  end

  # CYRA-632 — la query stava dentro Knowledge::FindRelatedPages; ora la condivide con la scrittura
  # assistita dei ticket, che pesca dalla stessa conoscenza.
  describe ".related_to_project" do
    let(:organization) { create(:organization) }
    let(:group) { create(:group, organization: organization) }
    let(:project) { create(:project, organization: organization, group: group) }

    it "prende le pagine agganciate al progetto" do
      page = create(:knowledge_page, project: project)

      expect(described_class.related_to_project(project)).to contain_exactly(page)
    end

    it "prende anche quelle agganciate al gruppo del progetto" do
      page = create(:knowledge_page, organization: organization, scoped: false)
      page.groups << group

      expect(described_class.related_to_project(project)).to contain_exactly(page)
    end

    # Il contesto conta: la guida di un altro progetto non aiuta qui, e una pagina che non è stata
    # agganciata a niente non è "di questo progetto".
    it "lascia fuori le pagine di altri progetti e quelle org-wide" do
      create(:knowledge_page, project: create(:project, organization: organization))
      create(:knowledge_page, organization: organization, scoped: false)

      expect(described_class.related_to_project(project)).to be_empty
    end

    # Questa relation non passa da .visible_to, quindi il filtro di stato va messo a mano: senza,
    # una proposta ancora in revisione finirebbe nel pannello del ticket e dentro il prompt.
    it "lascia fuori le proposte in revisione e le bocciate" do
      live = create(:knowledge_page, project: project)
      create(:knowledge_page, project: project, status: :in_review)
      create(:knowledge_page, project: project, status: :rejected)

      expect(described_class.related_to_project(project)).to contain_exactly(live)
    end

    it "non si rompe su un progetto senza gruppo" do
      orphan = create(:project, organization: organization, group: nil)
      page = create(:knowledge_page, project: orphan)

      expect(described_class.related_to_project(orphan)).to contain_exactly(page)
    end
  end

  describe "#effective_projects" do
    let(:organization) { create(:organization) }

    it "è vuoto per una pagina org-wide" do
      page = create(:knowledge_page, :org_wide, organization: organization)
      expect(page.effective_projects).to be_empty
    end

    it "unisce progetti diretti e progetti dei gruppi, senza duplicati" do
      group = create(:group, organization: organization)
      direct = create(:project, organization: organization)
      in_group = create(:project, organization: organization, group: group)
      shared = create(:project, organization: organization, group: group) # diretto E nel gruppo
      page = create(:knowledge_page, organization: organization, project: direct)
      page.projects << shared
      page.groups << group

      expect(page.effective_projects).to contain_exactly(direct, in_group, shared)
    end
  end

  describe "tag" do
    it "normalizza strip/downcase/uniq" do
      page = create(:knowledge_page, tags: [ "  Flutter ", "FLUTTER", "flutter-flavor", "" ])
      expect(page.tags).to eq(%w[flutter flutter-flavor])
    end

    it ".tagged_any filtra per overlap (almeno un tag in comune)" do
      a = create(:knowledge_page, tags: %w[flutter ios])
      b = create(:knowledge_page, tags: %w[android])
      c = create(:knowledge_page, tags: %w[flutter-flavor])

      result = described_class.tagged_any(%w[flutter android])

      expect(result).to include(a, b)
      expect(result).not_to include(c)
    end

    it ".distinct_tags elenca i tag ordinati e unici dello scope" do
      create(:knowledge_page, tags: %w[flutter ios])
      create(:knowledge_page, tags: %w[flutter android])

      expect(described_class.distinct_tags).to eq(%w[android flutter ios])
    end
  end

  describe "shim project (compatibilità serializer/viste/factory)" do
    it "#project ritorna il primo progetto, o nil per una pagina org-wide" do
      page = create(:knowledge_page)
      expect(page.project).to eq(page.projects.first)

      expect(create(:knowledge_page, :org_wide).project).to be_nil
    end

    it "#project= collega il progetto e fissa l'org se assente" do
      project = create(:project)
      page = described_class.new(title: "T", body: "B", created_by: create(:account))

      page.project = project

      expect(page.organization).to eq(project.organization)
      expect(page.projects).to include(project)
    end
  end

  describe ".visible_to" do
    let(:organization) { create(:organization) }
    let(:owner) { create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :owner) } }
    let(:member) { create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) } }

    it "mostra all'owner tutte le pagine, incluse le org-wide" do
      scoped = create(:knowledge_page, organization: organization, project: create(:project, organization: organization))
      org_wide = create(:knowledge_page, :org_wide, organization: organization)

      result = described_class.visible_to(account: owner, organization: organization)

      expect(result).to include(scoped, org_wide)
    end

    it "al member mostra solo le pagine dei progetti che vede, mai le org-wide" do
      visible_project = create(:project, organization: organization)
      create(:project_membership, account: member, project: visible_project)
      visible_page = create(:knowledge_page, organization: organization, project: visible_project)
      hidden_page = create(:knowledge_page, organization: organization, project: create(:project, organization: organization))
      org_wide = create(:knowledge_page, :org_wide, organization: organization)

      result = described_class.visible_to(account: member, organization: organization)

      expect(result).to include(visible_page)
      expect(result).not_to include(hidden_page, org_wide)
    end

    it "mostra al member una pagina collegata tramite un gruppo visibile" do
      group = create(:group, organization: organization)
      create(:group_membership, account: member, group: group)
      create(:project, organization: organization, group: group) # il gruppo contiene un progetto
      page = create(:knowledge_page, :org_wide, organization: organization)
      page.groups << group

      result = described_class.visible_to(account: member, organization: organization)

      expect(result).to include(page)
    end

    it "mostra una pagina collegata a un gruppo visibile SENZA progetti (creabile ma non fantasma)" do
      empty_group = create(:group, organization: organization) # nessun progetto dentro
      create(:group_membership, account: member, group: empty_group)
      page = create(:knowledge_page, :org_wide, organization: organization)
      page.groups << empty_group

      result = described_class.visible_to(account: member, organization: organization)

      expect(result).to include(page)
    end
  end

  describe "status (CYRA-298)" do
    it "nasce published, così il parco esistente resta visibile senza backfill" do
      expect(described_class.new.status).to eq("published")
    end

    it "tiene in .live solo le pagine pubblicate" do
      published = create(:knowledge_page)
      in_review = create(:knowledge_page, :in_review)
      rejected = create(:knowledge_page, :rejected)

      ids = described_class.live.pluck(:id)

      expect(ids).to include(published.id)
      expect(ids).not_to include(in_review.id, rejected.id)
    end

    it "tiene in .awaiting_review solo le pagine in attesa di una decisione" do
      in_review = create(:knowledge_page, :in_review)
      published = create(:knowledge_page)
      rejected = create(:knowledge_page, :rejected)

      ids = described_class.awaiting_review.pluck(:id)

      expect(ids).to eq([ in_review.id ])
      expect(ids).not_to include(published.id, rejected.id)
    end

    it "tiene in .awaiting_consolidation le sole accettate non ancora scritte su file" do
      da_scrivere = create(:knowledge_page, reviewed_at: Time.current)
      gia_scritta = create(:knowledge_page, reviewed_at: Time.current,
                                            consolidated_at: Time.current, source_path: "global/git.md")
      in_review = create(:knowledge_page, :in_review)

      ids = described_class.awaiting_consolidation.pluck(:id)

      expect(ids).to eq([ da_scrivere.id ])
      expect(ids).not_to include(gia_scritta.id, in_review.id)
    end

    it "non considera da archiviare le pagine scritte a mano, mai passate dalla revisione" do
      scritta_a_mano = create(:knowledge_page) # reviewed_at nil, come tutto il parco preesistente

      expect(described_class.awaiting_consolidation.pluck(:id)).not_to include(scritta_a_mano.id)
    end

    it "tiene la nota di revisione dentro il budget" do
      page = build(:knowledge_page, review_note: "x" * (Knowledge::Constants::REVIEW_NOTE_MAX_CHARS + 1))

      expect(page).not_to be_valid
      expect(page.errors[:review_note]).to be_present
    end
  end

  describe ".visible_to con lo stato (CYRA-298)" do
    let(:organization) { create(:organization) }
    let(:owner) { create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :owner) } }

    it "esclude di default le pagine in revisione e quelle scartate" do
      published = create(:knowledge_page, organization: organization, project: create(:project, organization: organization))
      in_review = create(:knowledge_page, :in_review, organization: organization, project: create(:project, organization: organization))
      rejected = create(:knowledge_page, :rejected, organization: organization, project: create(:project, organization: organization))

      result = described_class.visible_to(account: owner, organization: organization)

      expect(result).to include(published)
      expect(result).not_to include(in_review, rejected)
    end

    it "con status: :in_review restituisce la sola coda di revisione" do
      published = create(:knowledge_page, organization: organization, project: create(:project, organization: organization))
      in_review = create(:knowledge_page, :in_review, organization: organization, project: create(:project, organization: organization))

      result = described_class.visible_to(account: owner, organization: organization, status: :in_review)

      expect(result).to include(in_review)
      expect(result).not_to include(published)
    end

    it "con status: nil non filtra nulla (canali che gestiscono lo stato da sé)" do
      published = create(:knowledge_page, organization: organization, project: create(:project, organization: organization))
      in_review = create(:knowledge_page, :in_review, organization: organization, project: create(:project, organization: organization))

      result = described_class.visible_to(account: owner, organization: organization, status: nil)

      expect(result).to include(published, in_review)
    end
  end

  describe "cancellazione" do
    it "sopravvive alla cancellazione di un progetto collegato (si scollega, non cade)" do
      page = create(:knowledge_page)
      project = page.projects.first

      expect { project.destroy! }.not_to change(described_class, :count)
      expect(page.reload.projects).to be_empty
    end

    it "cade con l'organizzazione" do
      page = create(:knowledge_page)

      expect { page.organization.destroy! }.to change(described_class, :count).by(-1)
    end
  end

  # CYRA-419 — chi ha scritto il testo, separato dall'account il cui accesso è stato usato.
  describe "origine della pagina" do
    it "senza dato registrato non è né di un assistente né di una persona" do
      page = create(:knowledge_page)

      expect(page).to be_author_unregistered
      expect(page).not_to be_written_by_agent
    end

    it "l'etichetta dell'origine si normalizza e si tronca invece di invalidare la pagina" do
      page = create(:knowledge_page, :written_by_agent, author_origin: "  #{'x' * 200}  ")

      expect(page.author_origin.length).to eq(described_class::AUTHOR_ORIGIN_MAX_CHARS)
    end

    describe ".written_by" do
      let!(:da_assistente) { create(:knowledge_page, :written_by_agent) }
      let!(:da_persona) { create(:knowledge_page, :written_by_human) }
      let!(:non_registrata) { create(:knowledge_page) }

      it "isola le pagine scritte da un assistente" do
        expect(described_class.written_by([ "agent" ])).to contain_exactly(da_assistente)
      end

      it "«non registrata» è l'assenza del dato, non un valore dell'enum" do
        expect(described_class.written_by([ described_class::UNREGISTERED_AUTHOR ])).to contain_exactly(non_registrata)
      end

      it "più valori insieme si sommano" do
        selezione = described_class.written_by([ "agent", described_class::UNREGISTERED_AUTHOR ])

        expect(selezione).to contain_exactly(da_assistente, non_registrata)
      end

      it "un valore inventato non filtra niente invece di svuotare l'elenco" do
        expect(described_class.written_by([ "chiunque" ])).to contain_exactly(da_assistente, da_persona, non_registrata)
      end
    end
  end

  describe ".current_embedding (CYRA-168)" do
    it "tiene solo le righe della versione di embedding corrente, escludendo altra versione e nil" do
      current = create(:knowledge_page)
      current.update_columns(embedding: basis_vector(0), embedding_version: Ai::Constants::EMBEDDING_VERSION)
      stale = create(:knowledge_page)
      stale.update_columns(embedding: basis_vector(0), embedding_version: "qwen3-emb-0.6b-1024-v0")
      never_embedded = create(:knowledge_page) # embedding_version nil

      ids = described_class.current_embedding.pluck(:id)

      expect(ids).to include(current.id)
      expect(ids).not_to include(stale.id, never_embedded.id)
    end
  end

  # CYRA-768 — la data di rilettura: una pagina accettata non resta vera per sempre.
  describe "rilettura (review_after)" do
    it "considera da rileggere solo le pagine oltre la data" do
      scaduta = create(:knowledge_page, :decision)
      scaduta.update_columns(review_after: 1.day.ago)
      futura = create(:knowledge_page, :decision)
      futura.update_columns(review_after: 30.days.from_now)
      senza_scadenza = create(:knowledge_page)

      ids = described_class.needs_review.pluck(:id)

      expect(ids).to include(scaduta.id)
      expect(ids).not_to include(futura.id, senza_scadenza.id)
    end

    it "risponde di sì solo quando la data è passata" do
      page = create(:knowledge_page, :decision)

      page.review_after = 1.minute.ago
      expect(page).to be_needs_review

      page.review_after = 1.minute.from_now
      expect(page).not_to be_needs_review

      page.review_after = nil
      expect(page).not_to be_needs_review
    end

    # Scenario 2: la pagina scaduta si trova comunque. Nasconderla sarebbe peggio che mostrarla marcata.
    it "lascia in ricerca e fra le visibili anche una pagina oltre la data" do
      organization = create(:organization)
      project = create(:project, organization: organization)
      owner = create(:account).tap do |account|
        create(:membership, account: account, organization: organization, role: :owner)
      end
      page = create(:knowledge_page, :decision, organization: organization, project: project, title: "Scelta del proxy")
      page.update_columns(review_after: 1.day.ago)

      visibili = described_class.visible_to(account: owner, organization: organization)

      expect(visibili.pluck(:id)).to include(page.id)
      expect(visibili.text_search("proxy").pluck(:id)).to include(page.id)
    end
  end
end
