# frozen_string_literal: true

module Knowledge
  # Pagina della knowledge base: contenuto markdown scritto nell'app, più N file allegati
  # (Knowledge::Attachment — anche script, inerti: vedi lì). Distinta da Projects::Document, che
  # allega file al PROGETTO; qui il file appartiene alla pagina che lo spiega e muore con lei.
  # Collegata a N progetti e/o N gruppi, oppure org-wide (nessuno scope).
  # Visibilità = chi vede uno dei progetti/gruppi collegati; le org-wide solo chi ha accesso pieno
  # (vedi .visible_to). L'AUTORE gestisce le proprie pagine, le altrui sono gated (knowledge.edit/delete).
  class Page < ApplicationRecord
    include LengthBudget

    PUBLICATION_KEY_FORMAT = /\A[A-Za-z0-9][A-Za-z0-9._~:-]{0,254}\z/

    # CYRA-419: etichetta dell'assistente/skill/canale che ha scritto il testo. È un'etichetta di
    # servizio, non contenuto: si tronca invece di far fallire il salvataggio della pagina.
    AUTHOR_ORIGIN_MAX_CHARS = 80
    # Valore del filtro «Scritta da» per le pagine senza origine registrata (author_kind IS NULL).
    # Non è un valore dell'enum: l'assenza del dato non è un terzo tipo di autore.
    UNREGISTERED_AUTHOR = "unregistered"

    # Colonna infrastrutturale vector(1024), popolata SOLO da Knowledge::EmbedPageJob (mai da
    # form): abilita nearest_neighbors per ricerca semantica/pagine correlate.
    has_neighbors :embedding

    # CYRA-168: solo le righe embeddate con la versione CORRENTE del modello. Da anteporre a ogni
    # nearest_neighbors così un re-embed in corso (righe di versioni miste) non falsa le distanze.
    scope :current_embedding, -> { where(embedding_version: Ai::Configuration.current.embedding_version) }

    # Organizzazione = fonte d'org PRIMARIA denormalizzata: le pagine org-wide non hanno un progetto
    # da cui derivarla (a differenza del vecchio belongs_to :project). Version/PageLink/RecordVersion
    # leggono questa colonna, non più page.project.organization_id.
    belongs_to :organization,
               class_name: "Organizations::Organization",
               inverse_of: :knowledge_pages
    belongs_to :created_by, class_name: "Accounts::Account"
    # Chi ha accettato o scartato la proposta (CYRA-298). Nil finché la pagina non passa da una
    # decisione: le pagine scritte a mano dal web nascono pubblicate e non hanno un revisore.
    belongs_to :reviewed_by, class_name: "Accounts::Account", optional: true

    # Scope N:N: progetti diretti + gruppi (pattern Knowledge::Book). Zero progetti E zero gruppi =
    # pagina "generale" org-wide. Cleanup dei join via dependent: :destroy (come book_projects).
    has_many :page_projects,
             class_name: "Connections::PageProject",
             foreign_key: :page_id,
             inverse_of: :page,
             dependent: :destroy
    has_many :projects, through: :page_projects, source: :project
    has_many :page_groups,
             class_name: "Connections::PageGroup",
             foreign_key: :page_id,
             inverse_of: :page,
             dependent: :destroy
    has_many :groups, through: :page_groups, source: :group

    # Book (collezione) opzionale: la pagina può far parte di un book che include il suo progetto per la
    # vista Outline. position ordina la pagina nel TOC del book (assegnata da Knowledge::Books::Save).
    belongs_to :book,
               class_name: "Knowledge::Book",
               inverse_of: :pages,
               optional: true

    # Collegamenti pagina↔pagina derivati dai wikilink `[[Titolo]]` nel corpo (vedi
    # Knowledge::Links::Sync): `links` dove questa pagina cita, `inverse_links` dove è citata.
    # La lettura simmetrica passa da Connections::PageLink.involving. Cadono con la pagina.
    has_many :links,
             class_name: "Connections::PageLink",
             foreign_key: :page_id,
             inverse_of: :page,
             dependent: :destroy
    has_many :inverse_links,
             class_name: "Connections::PageLink",
             foreign_key: :related_id,
             inverse_of: :related,
             dependent: :destroy

    # File allegati alla pagina (CYRA-176). NON entrano nel testo di embedding né nelle versioni:
    # la ricerca semantica e la cronologia restano sul solo contenuto scritto (vedi
    # Knowledge::EmbeddingText::WATCHED_COLUMNS e Knowledge::Version). Cadono con la pagina.
    # Ordinata come l'associazione (non solo via scope): la card della show itera la collezione
    # PRECARICATA, e un .ordered a valle rifarebbe la query vanificando il preload.
    has_many :attachments,
             -> { order(:position, :created_at, :id) },
             class_name: "Knowledge::Attachment",
             inverse_of: :page,
             dependent: :destroy

    # Cronologia append-only: ogni salvataggio che cambia il contenuto congela uno snapshot
    # (Knowledge::Version). La pagina resta la LIVE/HEAD (contenuto corrente + embedding);
    # l'ultima versione (numero massimo) la rispecchia. Vedi Knowledge::RecordVersion.
    has_many :versions,
             -> { order(:number) },
             class_name: "Knowledge::Version",
             inverse_of: :page,
             dependent: :destroy

    # Funzionalità della matrice di prodotto documentate da questa pagina (CYRA-256). Nullify:
    # cancellare la pagina toglie il rimando, non la funzionalità.
    has_many :features,
             class_name: "Product::Feature",
             foreign_key: :knowledge_page_id,
             inverse_of: :knowledge_page,
             dependent: :nullify

    # Discriminator di forma (enum, non lookup CRUD — vedi rules/lookup-tables.md): ogni kind
    # guida template prefill e filtri dedicati nel codice (decision = ricerca decisioni, template
    # Contesto/Decisione/Conseguenze; guide/note = pagine libere). Un kind nuovo richiede codice.
    enum :kind, { note: 0, decision: 1, guide: 2 }, prefix: true

    # Stato di revisione (CYRA-298). published è 0 di proposito: il parco esistente resta live senza
    # backfill, e una pagina scritta a mano dal web nasce già pubblicata come prima. in_review è la
    # proposta di un assistente che aspetta un umano; rejected è la proposta bocciata, che resta
    # SOLO perché chi propone possa vederla cercando i duplicati e non riproporla domani.
    # Enum e non lookup CRUD (rules/lookup-tables.md): ogni valore guida codice — filtro di
    # visibilità, coda di revisione, enqueue dell'embedding.
    enum :status, { published: 0, in_review: 1, rejected: 2 }, prefix: true

    # CYRA-419 — CHI HA SCRITTO il testo, separato da created_by, che resta CHI POSSIEDE L'ACCESSO
    # usato per scriverlo. Erano la stessa cosa, e la pagina di un assistente si presentava firmata
    # da una persona: chi revisionava credeva di controllare il lavoro di un collega.
    # NULL è un valore legittimo — «origine non registrata» — e il default di ogni canale che non la
    # dichiara: attribuire a una persona per difetto è esattamente la firma sbagliata da togliere.
    # Enum e non lookup CRUD (rules/lookup-tables.md): ogni valore guida codice (segno in elenco,
    # filtro, decadenza alla riscrittura umana).
    enum :author_kind, { human: 0, agent: 1 }, prefix: :author

    # CYRA-764 — il verdetto del revisore AUTOMATICO sul testo live, congelato sulla riga come
    # `technical_body` (chip e filtri senza rileggere i corpi). Prefisso `ai_review_` per non
    # confondersi con `review_note`/`reviewed_by`, che sono la revisione UMANA. NULL = mai giudicata
    # (pagine nate prima del revisore, o salvate con l'interruttore spento).
    enum :ai_review_verdict, { accepted: 0, rejected: 1 }, prefix: :ai_review

    normalizes :title, with: ->(title) { title.strip }
    normalizes :body, with: ->(body) { LengthBudget.normalize_newlines(body).strip }
    # Sezione tecnica opzionale: strip + blank→NULL, così "vuoto" è sempre nil (tab/embedding puliti).
    normalizes :tech_spec, with: ->(tech_spec) { LengthBudget.normalize_newlines(tech_spec).strip.presence }
    # Nota di revisione: una riga sola, quindi strip + blank→NULL come tech_spec.
    normalizes :review_note, with: ->(note) { LengthBudget.normalize_newlines(note).strip.presence }
    # Origine: una parola sola (nome dell'assistente, della skill o del canale). Troncata invece che
    # validata — un'etichetta lunga non deve impedire di scrivere la pagina che descrive.
    normalizes :author_origin, with: ->(origin) { origin.to_s.strip.presence&.truncate(AUTHOR_ORIGIN_MAX_CHARS) }
    # Tag liberi (facet di filtro trasversali, es. "flutter"/"flutter-flavor"): normalizzati come
    # Projects::Document#tags (strip/downcase/uniq) — niente entità Tag, il filtro usa l'overlap &&.
    # apply_to_nil: un `tags: nil` esplicito (canale che non li invia) diventa [] e non viola il NOT NULL.
    normalizes :tags, apply_to_nil: true,
                      with: ->(tags) { Array(tags).map { |tag| tag.to_s.strip.downcase }.reject(&:blank?).uniq }

    validates :title, presence: true
    # Anche il titolo passa dal budget (non da un length secco): un titolo legacy oltre 255 non deve
    # bloccare ogni salvataggio della pagina, solo il proprio allungamento.
    length_budget :title, maximum: 255
    validates :body, presence: true
    # Il testo sta dentro il budget dell'embedding, e resta leggibile: vedi Knowledge::Constants.
    length_budget :body, maximum: Knowledge::Constants::BODY_MAX_CHARS
    length_budget :tech_spec, maximum: Knowledge::Constants::TECH_SPEC_MAX_CHARS
    length_budget :review_note, maximum: Knowledge::Constants::REVIEW_NOTE_MAX_CHARS
    validates :publication_key, length: { maximum: 255 }, allow_nil: true
    validates :publication_key, format: { with: PUBLICATION_KEY_FORMAT }, allow_nil: true
    validate :publication_key_cannot_change, on: :update

    scope :ordered, -> { order(updated_at: :desc) }
    # CYRA-298: da anteporre a ogni scope che finisce davanti a un utente o al RAG — gemello di
    # current_embedding per la ricerca. Il filtro vive dentro .visible_to, così i canali che già
    # passano di lì (Member, CLI, Ai::RunJob) lo ereditano senza saperlo; questi scope servono ai
    # due punti che costruiscono la propria relation da zero.
    scope :live, -> { where(status: :published) }
    scope :never_ai_reviewed, -> { where(ai_reviewed_at: nil) }
    scope :awaiting_review, -> { where(status: :in_review) }
    # Accettata in revisione ma non ancora scritta come documento nel repo della knowledge base.
    # reviewed_at NOT NULL è la parte che rende utile la lista: senza, ci finirebbe ogni pagina
    # scritta a mano dal web (consolidated_at è nil per default su tutto il parco esistente) e la
    # coda nascerebbe con decine di righe che non aspettano niente da nessuno.
    scope :awaiting_consolidation, -> { live.where(consolidated_at: nil).where.not(reviewed_at: nil) }
    # CYRA-768 — pagine oltre la data di rilettura. `review_after IS NULL` resta fuori da sé (in SQL
    # un confronto con NULL non è vero): le note, che non scadono, non entrano mai in coda. La
    # scadenza NON tocca la visibilità — una pagina scaduta si trova comunque, marcata (Scenario 2):
    # nasconderla vorrebbe dire far sparire l'unica traccia di come funzionava una cosa.
    scope :needs_review, -> { where(review_after: ..Time.current) }
    # CYRA-429: pagine il cui livello semplice è scritto in linguaggio tecnico. Il verdetto è
    # congelato al salvataggio (before_save), non ricalcolato in lettura: così l'elenco può dire
    # quante pagine aspettano una versione semplice senza rileggere il corpo di tutte.
    scope :without_simple_version, -> { where(technical_body: true) }
    # CYRA-419: pagine scritte da un assistente, in elenco e nei conteggi.
    scope :written_by_agent, -> { where(author_kind: :agent) }
    # Filtro «Scritta da» dell'elenco: uno o più valori dell'enum più UNREGISTERED_AUTHOR, che è
    # l'assenza del dato (IS NULL) e non un valore dell'enum — per questo la OR si compone in Arel
    # invece di passare l'elenco a una sola where.
    scope :written_by, lambda { |values|
      wanted = Array(values).map(&:to_s)
      kinds = wanted & author_kinds.keys
      unregistered = wanted.include?(UNREGISTERED_AUTHOR)
      next all if kinds.empty? && !unregistered

      conditions = []
      conditions << arel_table[:author_kind].in(kinds.map { |kind| author_kinds[kind] }) if kinds.any?
      conditions << arel_table[:author_kind].eq(nil) if unregistered
      where(conditions.reduce(:or))
    }

    before_save :evaluate_plain_language, if: :body_changed?
    # Overlap (OR): la pagina matcha se ha ALMENO uno dei tag selezionati (coerente coi filtri multi).
    scope :tagged_any, ->(tags) { where("knowledge_pages.tags && ARRAY[?]::text[]", Array(tags)) }
    # Filtro «progetto» delle liste (elenco pagine e coda di revisione, CYRA-560): la pagina matcha
    # se il progetto scelto è fra i suoi diretti O fra quelli dei gruppi collegati — altrimenti una
    # pagina collegata al gruppo di un progetto sparirebbe filtrando proprio quel progetto.
    # EXISTS e non joins: una pagina su N scope selezionati resterebbe duplicata nelle righe.
    scope :for_projects, lambda { |ids|
      where(
        "EXISTS (SELECT 1 FROM connections_page_projects pp WHERE pp.page_id = knowledge_pages.id AND pp.project_id IN (:ids)) " \
        "OR EXISTS (SELECT 1 FROM connections_page_groups pg JOIN projects p ON p.group_id = pg.group_id " \
        "WHERE pg.page_id = knowledge_pages.id AND p.id IN (:ids))", ids: ids
      )
    }
    # CYRA-573 — ricerca per parole esatte: titolo, corpo e parte tecnica, gli stessi tre campi che
    # Knowledge::EmbeddingText mette nel vettore. Guardava solo il titolo: una parola scritta nel
    # corpo non si trovava e al suo posto arrivava l'invito a creare una pagina già esistente, cioè
    # proprio il duplicato che la knowledge base esiste per evitare. Un posto solo perché la usano
    # due canali (elenco web e CLI): due ricerche testuali diverse sullo stesso archivio
    # risponderebbero in modo diverso alla stessa domanda. tech_spec è NULL sulle pagine senza
    # sezione tecnica — `NULL ILIKE` non è vero e la OR se ne occupa, nessun COALESCE.
    scope :text_search, lambda { |query|
      like = query.to_s.strip
      next all if like.blank?

      where("knowledge_pages.title ILIKE :q OR knowledge_pages.body ILIKE :q OR knowledge_pages.tech_spec ILIKE :q",
            q: "%#{like}%")
    }

    def authored_by?(account)
      account.present? && created_by_id == account.id
    end

    # CYRA-419 — il testo l'ha scritto un assistente: è il segno che resta in elenco e nel dettaglio
    # finché una persona non riscrive la pagina (Knowledge::SubstantiveEdit).
    def written_by_agent? = author_agent?

    # L'origine non è registrata: la pagina è nata prima che il prodotto la registrasse, o da un
    # canale che non la dichiara. Non vuol dire «scritta da una persona».
    def author_unregistered? = author_kind.nil?

    # Numero della versione live (= l'ultima). Nil finché non esiste alcuna versione.
    def current_version_number
      versions.maximum(:number)
    end

    # CYRA-419 — attributi d'origine da scrivere sulla pagina, in un posto solo (creazione e
    # riscrittura). L'etichetta ha senso soltanto per un assistente: una persona che scrive nell'app
    # non ha un canale da dichiarare, e portarsi dietro quella dell'assistente sarebbe una firma
    # rimasta lì dopo che la pagina è diventata sua.
    def self.authorship_attributes(kind:, origin: nil)
      { author_kind: kind, author_origin: (origin if kind.to_s == "agent") }
    end

    # Unione ordinata dei tag presenti nello scope: opzioni del filtro tag nell'index.
    def self.distinct_tags(scope = all)
      scope.pluck(Arel.sql("DISTINCT unnest(tags)")).sort
    end

    # Pagine visibili a un account nell'org. Full-access (owner/god) → tutte, incluse le org-wide.
    # Altrimenti solo quelle con un progetto O un GRUPPO visibile: le org-wide (zero scope) NON compaiono.
    # Il gruppo si matcha DIRETTAMENTE sui gruppi visibili (group_membership), non sui suoi progetti:
    # così una pagina collegata a un gruppo visibile ma SENZA progetti resta visibile a chi vede il
    # gruppo (altrimenti sarebbe creabile ma invisibile → 404 alla show). EXISTS (non joins): la
    # relation finisce in nearest_neighbors/.count e un join duplicherebbe le righe di una pagina
    # collegata a N scope visibili. project/group ids riusabili dal chiamante (concern memoizzato).
    #
    # status (CYRA-298) filtra PRIMA della visibilità ed è :published di default: ogni canale che
    # passa di qui — index member, CLI, RAG — smette di vedere le proposte in revisione e le
    # bocciate senza che nessuno lo debba ricordare. La coda di revisione chiede :in_review; solo
    # chi gestisce lo stato da sé passa nil.
    def self.visible_to(account:, organization:, full_access: nil, visible_project_ids: nil, visible_group_ids: nil,
                        status: :published)
      base = where(organization_id: organization.id)
      base = base.where(status: status) if status
      full_access = Authorization::VisibleScope.unscoped?(account: account, organization: organization) if full_access.nil?
      return base if full_access

      if visible_project_ids.nil? || visible_group_ids.nil?
        scope = Authorization::VisibleScope.new(account: account, organization: organization)
        visible_project_ids ||= scope.projects.select(:id)
        visible_group_ids ||= scope.groups.select(:id)
      end
      base.where(
        "EXISTS (SELECT 1 FROM connections_page_projects pp " \
        "WHERE pp.page_id = knowledge_pages.id AND pp.project_id IN (:project_ids)) " \
        "OR EXISTS (SELECT 1 FROM connections_page_groups pg " \
        "WHERE pg.page_id = knowledge_pages.id AND pg.group_id IN (:group_ids))",
        project_ids: visible_project_ids, group_ids: visible_group_ids
      )
    end

    # Pagine agganciate a UN progetto: collegate direttamente a lui O al suo gruppo (EXISTS sui
    # join N:N). Le org-wide non hanno join → escluse di proposito: il contesto conta, e una pagina
    # che non è stata agganciata a niente non è "di questo progetto". group_id nil (progetto senza
    # gruppo) → la seconda EXISTS è sempre falsa, nessun caso speciale da scrivere.
    #
    # .live va messo QUI a mano: questa relation non passa da visible_to, e senza filtro di stato
    # una proposta ancora in revisione finirebbe nel pannello del ticket (CYRA-298) e — da CYRA-632 —
    # dentro il prompt che scrive il ticket. Due chiamanti: Knowledge::FindRelatedPages (pannello
    # "correlata") e Ticketing::ComposeContext (contesto della scrittura assistita). Un posto solo
    # perché rispondono alla stessa domanda: cosa sa questo progetto?
    def self.related_to_project(project)
      live.where(organization_id: project.organization_id).where(
        "EXISTS (SELECT 1 FROM connections_page_projects pp " \
        "WHERE pp.page_id = knowledge_pages.id AND pp.project_id = :project_id) " \
        "OR EXISTS (SELECT 1 FROM connections_page_groups pg " \
        "WHERE pg.page_id = knowledge_pages.id AND pg.group_id = :group_id)",
        project_id: project.id, group_id: project.group_id
      )
    end

    # Progetti "effettivi": diretti + tutti quelli dei gruppi collegati (anche futuri). Gemello di
    # Knowledge::Book#effective_projects. Vuoto per le pagine org-wide.
    def effective_projects
      Projects::Project.where(id: direct_and_group_project_ids)
    end

    # Compatibilità coi caller ancora singolari (serializer/viste/factory): primo progetto o nil
    # (org-wide). project= collega il progetto e, se serve, fissa l'org dalla sua.
    def project = projects.first

    def project=(value)
      return if value.blank?

      self.organization ||= value.organization
      projects << value unless projects.include?(value)
    end

    def project_id = project&.id

    # CYRA-429: il livello semplice esiste solo se il corpo è davvero scritto in parole semplici.
    def simple_version_missing? = technical_body?

    # CYRA-768 — la data di rilettura è passata: la pagina va riguardata da una persona. Stato
    # DERIVATO, non una colonna: una colonna «scaduta» andrebbe riscritta ogni giorno da un giro
    # notturno, e il giorno che quel giro non parte l'app direbbe che è tutto attuale.
    def needs_review? = review_after.present? && review_after <= Time.current

    private

    # Il verdetto sul linguaggio si calcola quando il corpo cambia, non a ogni lettura: chi legge non
    # deve vedere un avviso che non può risolvere, e chi scrive lo riceve subito dopo il salvataggio.
    def evaluate_plain_language
      self.technical_body = Knowledge::PlainLanguageCheck.call(text: body).complex?
    end

    # Nil → chiave è l'adozione compatibile di una pagina legacy; dopo il primo binding l'identità
    # della fonte è stabile e non può essere riassegnata a un'altra publication_key.
    def publication_key_cannot_change
      return unless will_save_change_to_publication_key? && publication_key_in_database.present?

      errors.add(:publication_key, :readonly)
    end

    def direct_and_group_project_ids
      direct = Connections::PageProject.where(page_id: id).select(:project_id)
      group_ids = Connections::PageGroup.where(page_id: id).select(:group_id)
      Projects::Project.where(id: direct).or(Projects::Project.where(group_id: group_ids)).select(:id)
    end
  end
end
