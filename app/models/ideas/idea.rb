module Ideas
  # Idea di progetto: proposta grezza che il team fa maturare con voti e commenti, e che
  # l'autore (o chi ha ideas.convert) promuove a ticket. La conversione congela l'idea
  # (status converted, terminale, backlink al ticket); archived è reversibile.
  class Idea < ApplicationRecord
    # Progetto immutabile dopo la creazione (stessa invariante dei ticket): visibilità,
    # voti e commenti poggiano sull'org raggiunta via project → cambiarlo sarebbe un leak.
    attr_readonly :project_id

    # CYRA-167 — colonna infrastrutturale vector(1024), popolata SOLO da Ideas::EmbedIdeaJob (mai da
    # form): abilita nearest_neighbors per la ricerca per significato e per i doppioni suggeriti
    # mentre si propone un'idea.
    has_neighbors :embedding

    # Solo le righe embeddate con la versione CORRENTE del modello (CYRA-168). Da anteporre a ogni
    # nearest_neighbors così un re-embed in corso (righe di versioni miste) non falsa le distanze.
    scope :current_embedding, -> { where(embedding_version: Ai::Configuration.current.embedding_version) }

    belongs_to :project,
               class_name: "Projects::Project",
               inverse_of: :ideas
    # Autore = metadato "creato da" (nullify alla cancellazione dell'account): optional
    # perché l'idea viene mutata anche dopo (archive/convert) e deve restare valida.
    belongs_to :author,
               class_name: "Accounts::Account",
               inverse_of: :ideas,
               optional: true
    # Ticket nato dalla conversione (backlink, pattern Errors::Group#ticket). Se il ticket
    # muore l'idea resta converted e perde solo il link (FK on_delete: :nullify).
    belongs_to :ticket,
               class_name: "Ticketing::Ticket",
               inverse_of: :idea,
               optional: true

    has_many :comments,
             -> { order(:created_at) },
             class_name: "Ideas::Comment",
             foreign_key: :idea_id,
             inverse_of: :idea,
             dependent: :destroy

    # Case: esempi/scenari dell'idea, aggiunti una alla volta sulla pagina idea (come i commenti).
    # Contenuto dell'idea → congelati alla conversione/archiviazione (guard nei service).
    has_many :cases,
             -> { order(:created_at) },
             class_name: "Ideas::Case",
             foreign_key: :idea_id,
             inverse_of: :idea,
             dependent: :destroy

    # CYRA-845 — collegamenti fra idee (Ideas::Link). Un'evoluzione è un'idea a sé: qui vive solo il
    # filo. `parent` = l'idea di base di cui questa è evoluzione (al più una); `evolutions` = le idee
    # figlie; `related_out/in` = parenti alla pari nei due versi (una riga sola per coppia, letta da
    # entrambi i lati → `related_ideas` le unisce).
    has_many :outgoing_links, class_name: "Ideas::Link", foreign_key: :source_id,
                              inverse_of: :source, dependent: :destroy
    has_many :incoming_links, class_name: "Ideas::Link", foreign_key: :target_id,
                              inverse_of: :target, dependent: :destroy
    has_one :evolution_link, -> { kind_evolution }, class_name: "Ideas::Link", foreign_key: :source_id,
                             inverse_of: :source
    has_one :parent, through: :evolution_link, source: :target
    has_many :evolution_links, -> { kind_evolution }, class_name: "Ideas::Link", foreign_key: :target_id,
                               inverse_of: :target
    has_many :evolutions, through: :evolution_links, source: :source
    has_many :related_links_out, -> { kind_related }, class_name: "Ideas::Link", foreign_key: :source_id,
                                 inverse_of: :source
    has_many :related_links_in, -> { kind_related }, class_name: "Ideas::Link", foreign_key: :target_id,
                                inverse_of: :target
    has_many :related_out, through: :related_links_out, source: :target
    has_many :related_in, through: :related_links_in, source: :source

    # Voti (upvote): chiunque vede l'idea può votarla, 1 voto/account. votes_count denormalizzato
    # (counter_cache) per mostrare quante persone hanno segnalato interesse senza COUNT.
    # CYRA-360 — il voto NON ordina più niente e non fa scattare nulla: è solo il segnale di quante
    # persone vogliono l'idea, e la pagina lo dice a chiare lettere accanto al pulsante.
    has_many :votes,
             class_name: "Connections::IdeaVote",
             foreign_key: :idea_id,
             inverse_of: :idea,
             dependent: :destroy
    has_many :voters, through: :votes, source: :account

    # Activity-log generalizzato (polimorfico): cronologia create/update dell'idea.
    has_many :activity_events,
             class_name: "Activity::Event",
             as: :subject,
             dependent: :destroy

    # Radice di tenancy dell'idea = il progetto (delega, non colonna: project_id è attr_readonly).
    delegate :organization_id, to: :project

    # open = in discussione · converted = promossa a ticket (terminale, congelata) ·
    # archived = accantonata senza conversione (riapribile).
    enum :status, { open: 0, converted: 1, archived: 2 }, prefix: true

    normalizes :title, with: ->(value) { value.strip }
    # Corpo strutturato: problema (obbligatorio) + soluzione (opzionale), al posto del vecchio body.
    normalizes :problem, with: ->(value) { value.to_s.strip }
    normalizes :solution, with: ->(value) { value.to_s.strip }
    # CYRA-845 — come si ripaga e cosa la frena: fatti dell'idea, non commenti (opzionali, Markdown).
    normalizes :monetization, with: ->(value) { value.to_s.strip }
    normalizes :risks, with: ->(value) { value.to_s.strip }
    # Stakeholder = lista libera di tag (text[]). A differenza dei tag documento NON si fa downcase:
    # sono etichette visibili ("Team Mobile"). Strip + rimozione vuoti + dedup.
    # `apply_to_nil` è necessario, non decorativo: la colonna è NOT NULL con default [], ma un
    # chiamante che passa esplicitamente nil (form senza il campo, payload CLI parziale) scavalca il
    # default e senza normalizzazione l'INSERT muore con NotNullViolation — un 500, non un 422.
    normalizes :stakeholders, apply_to_nil: true,
                              with: ->(value) { Array(value).map { |s| s.to_s.strip }.reject(&:blank?).uniq }

    validates :title, presence: true
    validates :problem, presence: true
    validate :author_belongs_to_organization

    # Ordinamento della bacheca (CYRA-360): l'ultimo movimento, cioè `updated_at`, che commenti e
    # casi d'uso toccano (`touch: true` sui figli) mentre i voti no. Prima si ordinava per voti, ma
    # i voti erano zero ovunque: l'ordine che si vedeva era quello di creazione, mai dichiarato.
    # La creazione resta come criterio di parità: senza, due idee mai toccate escono in ordine
    # arbitrario e la lista cambia da un caricamento all'altro.
    scope :by_last_activity, -> { order(updated_at: :desc, created_at: :desc) }
    scope :recent, -> { order(created_at: :desc) }

    # Congelata: solo le idee open accettano voti, commenti, modifiche e conversione.
    # (NON chiamarla frozen? — è Object#frozen?, usato da ActiveRecord sui record distrutti.)
    def locked? = !status_open?

    # Evoluzione di un'altra idea (CYRA-845): la chip e il link «Evolve da» in pagina.
    def evolution? = evolution_link.present?

    # Parenti alla pari, in qualunque verso sia stata scritta la riga. Preload: related_out/related_in.
    def related_ideas = related_out + related_in

    def authored_by?(account)
      account.present? && author_id == account.id
    end

    private

    # Isolamento tenant (anti-BOLA): l'autore dev'essere membro dell'org del progetto.
    # Specchio di Ticketing::Comment#author_belongs_to_organization.
    def author_belongs_to_organization
      org_id = project&.organization_id
      return if org_id.blank? || author.blank?
      return if Connections::Membership.exists?(account_id: author.id, organization_id: org_id)

      errors.add(:author, :not_member)
    end
  end
end
