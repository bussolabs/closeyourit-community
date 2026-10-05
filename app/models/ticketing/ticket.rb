module Ticketing
  class Ticket < ApplicationRecord
    include Attachable
    include LengthBudget
    # Presa in carico, lavorazione, lapidi e rinvii di coda: le relazioni verso l'automazione le
    # dichiara il dominio agenti (CYRA-746), che è chi le possiede e chi le cambia.
    include Agents::TicketAutomatable

    # Il progetto (e quindi l'organizzazione) è IMMUTABILE dopo la creazione: la numerazione è
    # per-progetto e, soprattutto, gli eventi di cronologia denormalizzano organization_id a
    # create-time → cambiare progetto creerebbe un leak cross-tenant negli eventi storici.
    # attr_readonly blinda l'invariante su cui poggia lo scoping d'audit (vedi Ticketing::Event).
    attr_readonly :project_id

    # Colonna infrastrutturale vector(1024), popolata SOLO da Ticketing::EmbedTicketJob (mai da
    # form): abilita nearest_neighbors per ricerca semantica/duplicati (vedi Embeddings::EmbedText).
    has_neighbors :embedding

    # CYRA-168: solo le righe embeddate con la versione CORRENTE del modello. Da anteporre a ogni
    # nearest_neighbors così un re-embed in corso (righe di versioni miste) non falsa le distanze.
    scope :current_embedding, -> { where(embedding_version: Ai::Configuration.current.embedding_version) }

    belongs_to :project,
               class_name: "Projects::Project",
               inverse_of: :tickets
    belongs_to :reporter,
               class_name: "Accounts::Account",
               inverse_of: :reported_tickets
    belongs_to :assignee,
               class_name: "Accounts::Account",
               inverse_of: :assigned_tickets,
               optional: true
    # Revisore: chi verifica il lavoro quando il ticket entra in revisione. Nasce = reporter
    # (auto-fill in CreateTicket), ma è riassegnabile (Ticketing::SetReviewer). Riceve un ping
    # dedicato solo all'ingresso in uno status review_gate (vedi Notifications::DispatchEvent).
    belongs_to :reviewer,
               class_name: "Accounts::Account",
               inverse_of: :reviewed_tickets,
               optional: true
    belongs_to :status,
               class_name: "Types::TicketStatus",
               inverse_of: :tickets
    belongs_to :priority,
               class_name: "Types::TicketPriority",
               inverse_of: :tickets
    belongs_to :milestone,
               class_name: "Projects::Milestone",
               inverse_of: :tickets,
               optional: true

    # Epic padre (CYRA-223): un ticket qualsiasi può stare sotto UN epic dello stesso progetto, e
    # la gerarchia si ferma lì — un epic non sta sotto un altro epic. Alla destroy dell'epic i figli
    # restano vivi e si limitano a perdere il padre (FK on_delete: :nullify), come per la milestone:
    # cancellare il contenitore non deve portarsi via il lavoro che contiene.
    belongs_to :parent,
               class_name: "Ticketing::Ticket",
               inverse_of: :children,
               optional: true
    has_many :children,
             -> { order(:number) },
             class_name: "Ticketing::Ticket",
             foreign_key: :parent_id,
             inverse_of: :parent,
             dependent: :nullify

    has_many :ticket_platforms,
             class_name: "Connections::TicketPlatform",
             foreign_key: :ticket_id,
             inverse_of: :ticket,
             dependent: :destroy
    has_many :platforms, through: :ticket_platforms, source: :platform

    has_many :comments,
             -> { order(:created_at) },
             class_name: "Ticketing::Comment",
             foreign_key: :ticket_id,
             inverse_of: :ticket,
             dependent: :destroy

    # Resoconti di lavorazione (CYRA-220): uno per ticket, versionato. Il corrente è la versione col
    # numero più alto — non c'è una riga HEAD da mantenere allineata alla cronologia.
    has_many :reports,
             -> { order(:version) },
             class_name: "Ticketing::Report",
             foreign_key: :ticket_id,
             inverse_of: :ticket,
             dependent: :destroy
    has_one :current_report,
            -> { order(version: :desc) },
            class_name: "Ticketing::Report",
            foreign_key: :ticket_id,
            inverse_of: :ticket
    # L'ultima stesura che racconta un LAVORO CONSEGNATO (CYRA-389): la motivazione con cui si respinge
    # vive nel resoconto, quindi diventa la versione corrente, ma non è il lavoro — dove il prodotto
    # dichiara "questo è ciò che è stato consegnato" serve questa, non `current_report`.
    has_one :current_work_report,
            -> { delivered.order(version: :desc) },
            class_name: "Ticketing::Report",
            foreign_key: :ticket_id,
            inverse_of: :ticket

    # Snapshot immutabile della Guidance consegnata alla presa in carico (CYRA-76). Uno per ticket
    # (indice unico): nasce al claim, non alla creazione del ticket. Cade col ticket (è audit del ticket).
    has_one :work_context_snapshot,
            class_name: "Ticketing::WorkContextSnapshot",
            foreign_key: :ticket_id,
            inverse_of: :ticket,
            dependent: :destroy

    # Log collegati manualmente a questo ticket (vedi Logs::Link).
    has_many :log_links, class_name: "Logs::Link", as: :linkable, dependent: :destroy
    has_many :linked_log_entries, through: :log_links, source: :log_entry

    # Errore di monitoring promosso a QUESTO ticket (reverse di Errors::Group#ticket_id, CYRA-163).
    # has_one e non has_many: l'indice unico su errors_groups.ticket_id garantisce al più una
    # promozione per ticket (ogni promozione crea sempre un ticket nuovo, mai un riuso). Backlink di
    # sola lettura verso l'origine, mostrato sul dettaglio ticket.
    has_one :error_group, class_name: "Errors::Group", inverse_of: :ticket, dependent: nil
    # The slow operation linked to this ticket (unique index on metrics_groups.ticket_id).
    has_one :metric_group, class_name: "Metrics::Group", dependent: nil

    # Voci di todo personali che linkano questo ticket (link opzionale, vedi Todos::Item). Alla
    # cancellazione del ticket la voce sopravvive senza link (FK on_delete: :nullify).
    has_many :todo_items, class_name: "Todos::Item", foreign_key: :ticket_id,
                          inverse_of: :ticket, dependent: :nullify

    # Idea da cui questo ticket è nato (conversione, vedi Ideas::PromoteToTicket). Alla
    # cancellazione del ticket l'idea resta converted e perde solo il link (nullify).
    has_one :idea, class_name: "Ideas::Idea", foreign_key: :ticket_id,
                   inverse_of: :ticket, dependent: :nullify

    # Help desk requests that became this ticket or joined it (CYRA-941). On ticket deletion the
    # requests stay and lose the link (FK on_delete: :nullify).
    has_many :helpdesk_requests, class_name: "Helpdesk::Request", foreign_key: :ticket_id,
                                 inverse_of: :ticket, dependent: nil

    # Workload actions che linkano questo ticket (link opzionale, vedi Workload::Action). Alla
    # cancellazione del ticket la action sopravvive senza link (FK on_delete: :nullify).
    has_many :workload_actions, class_name: "Workload::Action", foreign_key: :ticket_id,
                                inverse_of: :ticket, dependent: :nullify

    # Cronologia/audit del ticket (cambi di stato, dati, allegati…). Cade col ticket:
    # la timeline vive nella show del ticket vivo (l'eliminazione del ticket non è tracciata).
    has_many :events,
             -> { order(:created_at, :id) },
             class_name: "Ticketing::Event",
             foreign_key: :ticket_id,
             inverse_of: :ticket,
             dependent: :destroy

    # Branch/PR GitHub collegati (integrazione GitHub, Fase 2): creati dal ticket o agganciati dal
    # webhook via prefisso KEY-N. Alla destroy del ticket il link si azzera (il record GitHub resta).
    has_many :github_branches,
             class_name: "Github::Branch",
             foreign_key: :ticket_id,
             inverse_of: :ticket,
             dependent: :nullify
    has_many :github_pull_requests,
             class_name: "Github::PullRequest",
             foreign_key: :ticket_id,
             inverse_of: :ticket,
             dependent: :nullify

    # Collegamenti ticket↔ticket del gate duplicati (vedi Connections::TicketLink): `links` dove
    # questo ticket è il nuovo, `inverse_links` dove è il preesistente. La lettura simmetrica
    # passa da Connections::TicketLink.involving(ticket). Cadono col ticket: sono metadato.
    has_many :links,
             class_name: "Connections::TicketLink",
             foreign_key: :ticket_id,
             inverse_of: :ticket,
             dependent: :destroy
    has_many :inverse_links,
             class_name: "Connections::TicketLink",
             foreign_key: :related_id,
             inverse_of: :related,
             dependent: :destroy

    # Dipendenze direzionali ticket↔ticket (CYRA-80, vedi Connections::TicketDependency): `dependencies`
    # sono le righe dove questo ticket è il DIPENDENTE (blockers = i ticket da cui dipende, prerequisiti);
    # `blocking` sono le righe dove questo ticket BLOCCA altri (dependents = i ticket che dipendono da
    # questo). Cadono col ticket (FK on_delete: :cascade ⇄ dependent: :destroy): sono metadato.
    has_many :dependencies,
             class_name: "Connections::TicketDependency",
             foreign_key: :ticket_id,
             inverse_of: :ticket,
             dependent: :destroy
    has_many :blockers, through: :dependencies, source: :blocker
    has_many :blocking,
             class_name: "Connections::TicketDependency",
             foreign_key: :blocker_id,
             inverse_of: :blocker,
             dependent: :destroy
    has_many :dependents, through: :blocking, source: :ticket

    # Voti (upvote) sul ticket: chiunque vede il ticket può votarlo, 1 voto/account.
    # votes_count denormalizzato (counter_cache) per ordinare la roadmap senza COUNT per riga.
    has_many :votes,
             class_name: "Connections::TicketVote",
             foreign_key: :ticket_id,
             inverse_of: :ticket,
             dependent: :destroy
    has_many :voters, through: :votes, source: :account

    # Sottoscrizioni (watcher): chi riceve le notifiche dei cambiamenti del ticket. Cadono col
    # ticket (FK on_delete: :cascade, AR dependent: :destroy): sono preferenza, non evidenza.
    has_many :subscriptions,
             class_name: "Ticketing::Subscription",
             foreign_key: :ticket_id,
             inverse_of: :ticket,
             dependent: :destroy
    has_many :subscribers, through: :subscriptions, source: :account

    # Scenari BDD del ticket: N Given/When/Then/Expected ordinati, human-simple, tutti i kind
    # (sostituiscono le 4 colonne step_* piatte). Cadono col ticket.
    has_many :scenarios,
             -> { order(:position, :created_at) },
             class_name: "Ticketing::Scenario",
             foreign_key: :ticket_id,
             inverse_of: :ticket,
             dependent: :destroy

    # Domande poste sul ticket (CYRA-779), con le loro risposte. Cadono col ticket: sono la memoria
    # di uno scambio su QUESTO lavoro, come i commenti, e non hanno senso senza di esso.
    has_many :questions,
             -> { order(:created_at, :id) },
             class_name: "Ticketing::Question",
             foreign_key: :ticket_id,
             inverse_of: :ticket,
             dependent: :destroy

    # Definition of Done: N righe-condizione opzionali, ordinate. Cadono col ticket.
    has_many :conditions,
             -> { order(:position, :created_at) },
             class_name: "Ticketing::Condition",
             foreign_key: :ticket_id,
             inverse_of: :ticket,
             dependent: :destroy

    # Nested attributes per il form (repeater) e i service condivisi. reject_if scarta le righe vuote:
    # uno scenario senza alcuno step, una condizione senza testo — così "aggiungi riga" a vuoto non crea record.
    accepts_nested_attributes_for :scenarios, allow_destroy: true,
      reject_if: ->(attrs) { Ticketing::Scenario::STEP_FIELDS.all? { |field| attrs[field.to_s].to_s.strip.blank? } }
    accepts_nested_attributes_for :conditions, allow_destroy: true,
      reject_if: ->(attrs) { attrs["text"].to_s.strip.blank? }

    # Discriminatore di forma (enum, non lookup): il corpo del ticket è uguale per tutti i kind, il
    # kind cambia solo dominio e UI, e non dipende da nessun flag di progetto. `validate: true` è
    # load-bearing: senza, un kind fuori vocabolario solleva ArgumentError dall'assegnazione (500)
    # invece di diventare un errore di campo (422). CYRA-223
    enum :kind, { bug: 0, story: 1, task: 2, epic: 3 }, prefix: true, validate: true

    # Gate di eleggibilità agenti (CYRA-184). `pending` è il default della COLONNA, non una scelta
    # applicativa: un ticket che nessuno ha ancora esaminato non raggiunge gli agenti autonomi, e
    # nemmeno lo raggiunge un ticket la cui valutazione è fallita (l'errore non scrive nulla).
    enum :agent_eligibility, { pending: 0, allowed: 1, blocked: 2 }, prefix: :agent_eligibility
    # Chi ha deciso, come CATEGORIA di decisore. È la stickiness dell'override umano: finché vale
    # `human`, nessuna rivalutazione automatica può sovrascrivere il verdetto.
    enum :agent_eligibility_source, { automatic: 0, human: 1 }, prefix: :agent_eligibility_source
    # CYRA-770 — il PARERE dell'AI, che è un asse diverso dalla DECISIONE qui sopra. La coda degli
    # agenti legge `agent_eligibility` e non guarda mai questa colonna: il parere informa chi decide,
    # non apre nulla. `unknown` vuol dire «l'AI non si è ancora espressa», e convive con qualunque
    # decisione — un ticket consentito a mano prima della valutazione resta consentito senza parere.
    enum :agent_eligibility_advice, { unknown: 0, allowed: 1, blocked: 2 }, prefix: :agent_eligibility_advice

    # Attribuzione dell'override, non logica: la FK è nullify, quindi questo campo può sparire senza
    # che la decisione cambi. L'attore storico completo, con nome snapshottato, vive in
    # Ticketing::Event (action agent_eligibility_overridden).
    belongs_to :agent_eligibility_decided_by,
               class_name: "Accounts::Account",
               inverse_of: false,
               optional: true

    normalizes :title, with: ->(title) { Text::ItalianOrthography.correct(title).strip }
    # La correzione ortografica sta QUI e non nei service: deve valere per ogni percorso di scrittura
    # (form, CLI, promozione da errore) e per il testo di chiunque — «perché» senza accento è un
    # errore anche quando l'ha scritto una persona. Vedi Text::ItalianOrthography.
    normalizes :description,
               with: ->(value) { Text::ItalianOrthography.correct(LengthBudget.normalize_newlines(value)).strip }
    normalizes :technical_analysis,
               with: ->(value) { Text::ItalianOrthography.correct(LengthBudget.normalize_newlines(value)).strip }
    # La motivazione dell'eleggibilità agenti la scrive un modello (Ticketing::EvaluateAgentEligibility)
    # e finisce sotto gli occhi di chi decide se un agente può lavorare il ticket.
    normalizes :agent_eligibility_reason, with: ->(value) { Text::ItalianOrthography.correct(value).strip }
    # Stessa provenienza, stesso trattamento: il motivo del parere lo scrive lo stesso modello.
    normalizes :agent_eligibility_advice_reason,
               with: ->(value) { Text::ItalianOrthography.correct(value).strip }

    validates :title, presence: true
    # Il corpo resta leggibile e sta dentro il budget dell'embedding: vedi Ticketing::Constants. Il
    # titolo passa dallo stesso budget (non da un length secco) così un titolo legacy oltre 255 non
    # blocca ogni salvataggio del ticket, solo il proprio allungamento.
    length_budget :title, maximum: 255
    length_budget :description, maximum: Ticketing::Constants::DESCRIPTION_MAX_CHARS
    length_budget :technical_analysis, maximum: Ticketing::Constants::TECHNICAL_ANALYSIS_MAX_CHARS
    # Corpo minimo, uguale per tutti i kind: dev'essere SEMPRE salvabile con testo semplice. Il minimo
    # è "titolo + almeno un corpo" — cioè una `description` libera OPPURE almeno uno scenario con
    # contenuto. Scenari, DoD e technical_analysis sono opzionali (l'assistente AI suggerisce/pre-compila):
    # non bloccano il salvataggio.
    validate :requires_some_body
    # Peso/punti opzionale (story points). Se valorizzato dev'essere un intero positivo.
    validates :weight, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
    validates :number, uniqueness: { scope: :project_id }, allow_nil: true
    validate :status_and_priority_match_organization
    validate :reporter_and_assignee_belong_to_organization
    validate :affected_platforms_within_project
    validate :milestone_belongs_to_project
    validate :parent_is_an_epic_of_the_same_project
    validate :epic_stays_at_the_top
    validate :epic_with_children_keeps_its_kind

    before_create :assign_number
    # closed_at segue la category dello status (done → set, riapertura → nil): sync nel model
    # così OGNI percorso di mutazione (ChangeStatus, ApproveReview, UpdateTicket, create diretto)
    # mantiene l'invariante senza duplicare la logica nei service. Non è normalizzazione di input
    # (rules/rails/models.md): è stato derivato dal dominio, mai scrivibile dal form.
    before_save :sync_closed_at, if: :status_id_changed?

    # Candidati del gate duplicati: aperti/in lavorazione sempre, chiusi solo dentro la finestra
    # (Ticketing::Constants::DUPLICATE_CLOSED_WINDOW). Componibile con la scope di visibilità.
    scope :open_or_recently_closed, lambda {
      categories = Types::TicketStatus.categories
      joins(:status)
        .where(types_ticket_statuses: { category: [ categories[:open], categories[:in_progress] ] })
        .or(joins(:status).where(types_ticket_statuses: { category: categories[:done] })
                          .where(closed_at: Ticketing::Constants::DUPLICATE_CLOSED_WINDOW.ago..))
    }

    # «Aspetta una MIA decisione»: revisore designato, status con gate di revisione, ticket non
    # concluso. È l'UNICA definizione — la usano la coda delle Approvazioni e il contatore in testa a
    # board e lista, e due query per la stessa domanda darebbero due numeri. Senza account → `none`:
    # un `reviewer_id: nil` pescherebbe i ticket SENZA revisore, l'opposto. CYRA-374
    scope :awaiting_review_by, lambda { |account|
      reviewer_id = account_id_for(account)
      next none if reviewer_id.blank?

      joins(:status)
        .where(reviewer_id: reviewer_id, types_ticket_statuses: { review_gate: true })
        .where.not(types_ticket_statuses: { category: Types::TicketStatus.categories.fetch("done") })
    }

    # Il record o il suo id, indifferentemente: chi chiama ha `Current.account` (record), la coda un
    # record, un filtro una stringa dalla query string.
    def self.account_id_for(account)
      account.respond_to?(:id) ? account.id : account.presence
    end

    def code
      "#{project.key}-#{number}"
    end

    # Gemello IN MEMORIA di .awaiting_review_by (parità verificata da spec): lo interrogano le righe di
    # lista e le card di board, che hanno già lo status precaricato — una query per riga sarebbe un N+1
    # su ogni pagina di ticket.
    def awaiting_review_by?(account)
      reviewer = self.class.account_id_for(account)
      return false if reviewer.blank? || reviewer_id.blank? || reviewer_id != reviewer

      status.present? && status.review_gate? && !status.category_done?
    end

    # Lettura UNICA del gate: chi deve sapere "gli agenti possono lavorarlo?" chiede qui, mai
    # all'enum grezzo. Così aggiungere un domani un quarto stato non richiede una caccia ai call site
    # (oggi: Agents::TicketQueues::Next e CandidateSnapshot#eligible?).
    def agent_workable?
      agent_eligibility_allowed?
    end

    # La valutazione automatica è da rifare? La decisione UMANA è sticky: nessun cambio di corpo o di
    # allegati la rende stale, solo un reset esplicito la riporta al percorso automatico.
    def agent_eligibility_stale?
      return false if agent_eligibility_source_human?

      agent_eligibility_checksum != Ticketing::AgentEligibilityText.checksum(ticket: self)
    end

    # Dipendenze non soddisfatte: i blocker non in uno status done (category dell'enum, mai per code),
    # con query pura per non pagare N+1. `:released` (default) chiede il prerequisito rilasciato e
    # provato vivo, `:merged` solo il codice unito e provato — è ciò che fa uscire due ticket messi in
    # fila. Il fatto di `:merged` è `closer_staging_verified_at`, del verificatore. CYRA-80, CYRA-622, CYRA-620
    def unmet_dependencies(mode: :released)
      dependencies.merge(Connections::TicketDependency.unmet(mode:))
    end

    # Bloccato = ha almeno una dipendenza non soddisfatta. Nessun effetto sul workflow ancora: è il
    # ticket sul gating a decidere se il blocco impedisce la lavorazione (CYRA-80 è il primo di 4).
    def blocked?
      unmet_dependencies.exists?
    end

    # Lavorabile = non bloccato. Predicato TOTALE, definito anche per un ticket già done (un done
    # senza blocker aperti è workable?; non ha semantica di "da lavorare", ma la domanda ha risposta).
    def workable?
      !blocked?
    end

    # Da quando il ticket è nello status corrente (CYRA-392): l'istante dell'ultimo cambio di stato
    # nella cronologia, o la creazione se non è mai cambiato. È l'unica fonte del tempo di permanenza
    # (non esiste una colonna status_changed_at): l'ingresso in uno stato è timbrato solo dagli eventi
    # Ticketing::Event con action "status_changed".
    def current_status_since
      events.where(action: "status_changed").maximum(:created_at) || created_at
    end

    private

    # Entra in uno status done → timbra l'istante (una sola volta: done→done conserva
    # l'originale); esce dalla category done → azzera (riaperto = non più "chiuso").
    def sync_closed_at
      if status&.category_done?
        self.closed_at ||= Time.current
      else
        self.closed_at = nil
      end
    end

    # Numero progressivo per progetto, monotòno (sopravvive ai delete): lock sulla riga
    # del progetto per serializzare i create concorrenti ed evitare numeri duplicati.
    def assign_number
      return if number.present?

      project_row = Projects::Project.lock.find(project_id)
      self.number = project_row.last_ticket_number + 1
      project_row.update_column(:last_ticket_number, number)
    end

    # Corpo minimo: sempre salvabile con testo semplice → basta una `description` libera OPPURE almeno
    # uno scenario con contenuto. Se manca tutto, errore su :description (il form lo mostra vicino al
    # campo descrizione). Gli scenari già costruiti dai nested attributes sono in `scenarios`; le righe
    # step-less sono già state scartate da reject_if, ma escludo comunque i marcati per destroy.
    def requires_some_body
      return if description.present?
      return if scenarios.reject(&:marked_for_destruction?).any?(&:steps?)

      errors.add(:description, :body_required)
    end

    # Integrità tenant: status e priority devono appartenere all'org del progetto.
    def status_and_priority_match_organization
      org_id = project&.organization_id
      return if org_id.blank?

      errors.add(:status, :invalid)   if status&.organization_id   && status.organization_id   != org_id
      errors.add(:priority, :invalid) if priority&.organization_id && priority.organization_id != org_id
    end

    # Isolamento tenant (anti-BOLA): reporter, assignee e reviewer devono essere membri
    # dell'organizzazione del progetto. Gli Account sono N:M con le org via
    # Connections::Membership (niente organization_id diretto come status/priority).
    def reporter_and_assignee_belong_to_organization
      org_id = project&.organization_id
      return if org_id.blank?

      errors.add(:reporter, :not_member) if reporter && !member_of?(reporter, org_id)
      errors.add(:assignee, :not_member) if assignee && !member_of?(assignee, org_id)
      errors.add(:reviewer, :not_member) if reviewer && !member_of?(reviewer, org_id)
    end

    def member_of?(account, org_id)
      Connections::Membership.exists?(account_id: account.id, organization_id: org_id)
    end

    # Vincolo dominio: le piattaforme colpite sono un subset di quelle dichiarate dal progetto.
    # Piattaforma opzionale (un bug può essere platform-agnostico) → vale solo se ne scegli.
    def affected_platforms_within_project
      return if project.blank? || platforms.empty?

      allowed = project.platform_ids
      errors.add(:platforms, :not_in_project) if platforms.any? { |platform| allowed.exclude?(platform.id) }
    end

    # Integrità: la milestone (opzionale) dev'essere DELLO STESSO progetto del ticket (le milestone
    # sono per-progetto, ogni progetto la sua roadmap). Non basta la stessa org.
    def milestone_belongs_to_project
      return if project.blank? || milestone.blank?

      errors.add(:milestone, :invalid) if milestone.project_id != project_id
    end

    # Il padre dev'essere un EPIC dello STESSO progetto. Il vincolo di progetto è la stessa difesa
    # della milestone: senza, un ticket potrebbe agganciarsi a un epic di un'altra organizzazione e
    # leggerne il codice nella propria pagina. L'auto-riferimento è possibile solo in update (su un
    # record nuovo l'id non esiste ancora), quindi va chiuso qui e non solo in UI.
    def parent_is_an_epic_of_the_same_project
      return if parent.blank?

      errors.add(:parent, :self_reference) if parent_id == id
      errors.add(:parent, :not_epic) unless parent.kind_epic?
      errors.add(:parent, :invalid) if parent.project_id != project_id
    end

    # Un epic è il livello alto della gerarchia: non sta sotto nulla. Un solo livello, sempre.
    def epic_stays_at_the_top
      errors.add(:parent, :epic_cannot_be_nested) if kind_epic? && parent_id.present?
    end

    # Un epic che ha figli non può smettere di essere un epic: i figli resterebbero appesi a un
    # ticket che non è un contenitore. Prima si staccano i figli, poi si cambia il tipo.
    def epic_with_children_keeps_its_kind
      return unless persisted? && kind_changed? && kind_was == "epic"
      return unless children.exists?

      errors.add(:kind, :epic_has_children)
    end
  end
end
