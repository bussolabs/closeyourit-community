# frozen_string_literal: true

module Activity
  # CYRA-745 — vista unificata di LETTURA di «chi ha fatto cosa e quando». Il prodotto scrive le azioni
  # delle persone in registri separati, uno per dominio, e finora ognuno si leggeva (quando si leggeva)
  # in un posto diverso: quello dei PERMESSI non si leggeva da nessuna parte — il dato c'era e la
  # domanda «chi ha dato questo permesso» restava senza risposta.
  #
  # L'unificazione avviene QUI, in lettura, e non riscrivendo lo storico in una tabella sola: i registri
  # dei segreti sono audit immutabile (`attr_readonly`, append-only) e un audit che si può riscrivere non
  # è più un audit. Riusa Secrets::AuditQuery invece di ricopiarne le tre sorgenti: il confine dei
  # progetti visibili e la forma delle righe del Vault restano scritti in un posto solo.
  #
  # Quattro sorgenti, tutte org-scoped:
  #   work        Activity::Event        progetti, documenti, milestone, dataset, idee, carico di lavoro
  #   tickets     Ticketing::Event       cronologia dei ticket dei progetti visibili
  #   permissions Authorization::Event   ruoli, permessi, team, conferme di azioni pericolose
  #   secrets     Secrets::AuditQuery    variabili di progetto, variabili condivise, file (3 registri)
  #
  # I due registri PERSONALI (secrets_personal_events, secrets_personal_asset_events) restano fuori,
  # con la stessa motivazione di CYRA-135: sono account-scoped e privati di chi li ha generati, non
  # materiale d'audit dell'organizzazione. Portarli qui esporrebbe a un amministratore la cassaforte
  # personale delle persone, che è esattamente ciò che il livello «personale» promette di non fare.
  class AuditQuery
    # Riga normalizzata: forma unica su cui la vista non deve conoscere i sei schemi sorgente.
    # `true_actor` non è un di più: un registro che dice «Tizio ha tolto quel permesso» quando l'ha
    # fatto un amministratore entrato nei suoi panni attribuisce l'azione alla persona sbagliata, ed è
    # il difetto peggiore che un registro di responsabilità possa avere. I registri del Vault non hanno
    # la colonna (non passano da impersonation): lì resta nil, e nil vuol dire «l'ha fatto chi risulta».
    Row = Data.define(:occurred_at, :source, :action, :actor, :actor_name, :true_actor,
                      :subject_label, :project_id, :subject) do
      def impersonated? = true_actor.present? && true_actor != actor
    end

    # I registri unificati, per sorgente e nell'ordine in cui la UI li offre. Chiavi stabili: finiscono
    # nell'indirizzo. È l'elenco DI PRODUZIONE, non una copia per le prove: le azioni del filtro si
    # ricavano da qui, e il guard del registro unico (spec/config/activity_single_log_spec.rb) legge
    # questo per sapere quali tabelle registro sono già leggibili da una pagina.
    SOURCE_MODELS = {
      work: [ Activity::Event ],
      tickets: [ Ticketing::Event ],
      permissions: [ Authorization::Event ],
      secrets: Secrets::AuditQuery::SOURCE_MODELS
    }.freeze

    SOURCES = SOURCE_MODELS.keys.freeze

    # Quando nessuno chiede un limite si prende comunque una finestra, non tutto: `ticketing_events`
    # cresce senza fine e una pagina non deve poter caricare un milione di righe per mostrarne venti.
    DEFAULT_LIMIT = 500

    # Le azioni possibili per sorgente: alimentano il filtro azione della pagina.
    def self.actions_for(source)
      SOURCE_MODELS.fetch(source.to_sym, []).flat_map { |model| model::ACTIONS }.uniq
    end

    # Tutte le azioni conosciute, in ordine di sorgente e senza doppioni (il filtro azione «tutte»).
    def self.all_actions = SOURCES.flat_map { |s| actions_for(s) }.uniq.freeze

    # `include_moves`: owners also see the projects moved in or out, visible here or not (CYRA-879).
    def initialize(organization:, visible_project_ids:, visible_team_ids:, include_secrets:,
                   filters: {}, limit: DEFAULT_LIMIT, include_moves: false, oldest_first: false)
      @organization = organization
      @include_moves = include_moves
      @visible_project_ids = Array(visible_project_ids)
      @visible_team_ids = Array(visible_team_ids)
      @include_secrets = include_secrets
      @filters = (filters || {}).compact_blank
      @limit = [ limit.to_i, 1 ].max
      @oldest_first = oldest_first
    end

    # Una pagina di righe, nella forma che Ui::PaginationComponent già consuma. Sta QUI e non nel
    # controller perché è l'unico posto che sa quanto va chiesto a ciascuna sorgente: per servire la
    # pagina N servono le prime N×per righe di ogni registro, non tutte e non solo `per`.
    def self.page(page:, per:, **options)
      query = new(**options, limit: 1)
      total = query.total
      total_pages = total.zero? ? 1 : (total.to_f / per).ceil
      page = page.to_i.clamp(1, total_pages)

      window = new(**options, limit: page * per).rows
      Pagination::Result.new(records: window.slice((page - 1) * per, per) || [],
                             page: page, per: per, total: total, total_pages: total_pages)
    end

    # Le righe più recenti, al massimo `limit`. Ogni sorgente contribuisce con le sue prime `limit`
    # righe: prendendo le N più recenti di ogni lista già ordinata, le N più recenti dell'unione sono
    # comunque quelle giuste — nessuna riga più recente può nascondersi oltre il taglio.
    # CYRA-924 — `oldest_first:` reads every register the other way round, so the same cut keeps the
    # oldest rows instead.
    def rows
      @rows ||= begin
        unite = sources.flat_map { |source| rows_from(source) }.sort_by(&:occurred_at)
        (@oldest_first ? unite : unite.reverse).first(@limit)
      end
    end

    # Conteggio ESATTO, non quello della finestra: la chip del titolo dice quanto c'è, e un taglio di
    # pagina non deve poterlo far sembrare più piccolo di quello che è.
    def total
      @total ||= sources.sum { |source| count_from(source) }
    end

    private

    # Le sorgenti effettivamente interrogate: il filtro le riduce a una, il permesso del Vault decide
    # se i segreti entrano. Un filtro su una sorgente sconosciuta non ne apre nessuna.
    def sources
      wanted = @filters[:source].presence&.to_sym
      available = @include_secrets ? SOURCES : SOURCES - [ :secrets ]
      wanted ? available & [ wanted ] : available
    end

    def rows_from(source)
      case source
      when :work        then work_rows
      when :tickets     then ticket_rows
      when :permissions then permission_rows
      when :secrets     then secret_rows
      else []
      end
    end

    def count_from(source)
      case source
      when :work        then filtered(work_scope).count
      when :tickets     then filtered(ticket_scope).count
      when :permissions then filtered(permission_scope).count
      when :secrets     then secrets_query.total
      else 0
      end
    end

    # --- Sorgenti -------------------------------------------------------------------------------

    def work_rows
      filtered(work_scope).order(created_at: direction, id: direction).limit(@limit).map do |event|
        Row.new(occurred_at: event.created_at, source: :work, action: event.action,
                actor: event.actor, actor_name: actor_name_for(event), true_actor: event.true_actor,
                subject_label: subject_label(event.subject), project_id: project_id_for(event.subject),
                subject: event.subject)
      end
    end

    def ticket_rows
      filtered(ticket_scope).order(created_at: direction, id: direction).limit(@limit).map do |event|
        Row.new(occurred_at: event.created_at, source: :tickets, action: event.action,
                actor: event.actor, actor_name: actor_name_for(event), true_actor: event.true_actor,
                subject_label: event.ticket&.code, project_id: event.ticket&.project_id, subject: event.ticket)
      end
    end

    def permission_rows
      filtered(permission_scope).order(created_at: direction, id: direction).limit(@limit).map do |event|
        Row.new(occurred_at: event.created_at, source: :permissions, action: event.action,
                actor: event.actor, actor_name: actor_name_for(event), true_actor: event.true_actor,
                subject_label: permission_subject(event.data), project_id: nil, subject: nil)
      end
    end

    # I tre registri del Vault arrivano già unificati e già confinati ai progetti visibili.
    def secret_rows
      secrets_query.rows.map do |row|
        Row.new(occurred_at: row.occurred_at, source: :secrets, action: row.action,
                actor: row.actor, actor_name: row.actor&.name, true_actor: nil,
                subject_label: row.name, project_id: row.project_id, subject: nil)
      end
    end

    # `limit:` non è un dettaglio: senza, i tre registri del Vault si caricano INTERI in memoria e si
    # ordinano in Ruby a ogni apertura della pagina, e la paginazione qui sopra non serve a niente.
    def secrets_query
      @secrets_query ||= Secrets::AuditQuery.new(
        organization: @organization,
        visible_project_ids: @visible_project_ids,
        filters: @filters.slice(:action, :actor_id, :from, :to),
        limit: @limit,
        oldest_first: @oldest_first
      )
    end

    # --- Scope ----------------------------------------------------------------------------------

    # Il registro generico è POLIMORFICO: `organization_id` da solo lascerebbe leggere che cosa succede
    # dentro un progetto a cui l'account non è assegnato — il documento caricato, il traguardo spostato,
    # l'idea aperta — ed è proprio una pagina che raccoglie tutto in un posto a rendere comodo
    # accorgersene. Il confine si applica per TIPO di soggetto, perché i tipi non hanno tutti la stessa
    # radice: cinque appartengono a un progetto, il carico di lavoro appartiene a un TEAM.
    #
    # Fail-closed: un tipo di soggetto non previsto qui NON entra. Un'attività che non si vede è un
    # difetto che si nota e si aggiusta; una che si vede senza averne diritto no.
    def work_scope
      Activity::Event
        .where(organization_id: @organization.id)
        .where(visible_subjects_condition)
        .includes(:actor, :subject)
    end

    # I tipi di soggetto del registro generico e come si risale al loro confine di visibilità.
    # `:self` = il soggetto È il progetto (l'id della riga è già l'id del progetto).
    VISIBLE_SUBJECTS = {
      "Projects::Project" => :self,
      "Projects::Document" => [ Projects::Document, :project_id ],
      "Projects::Milestone" => [ Projects::Milestone, :project_id ],
      "Datasets::Dataset" => [ Datasets::Dataset, :project_id ],
      "Ideas::Idea" => [ Ideas::Idea, :project_id ]
    }.freeze

    def visible_subjects_condition
      events = Activity::Event.arel_table

      conditions = VISIBLE_SUBJECTS.map do |kind, rule|
        ids = rule == :self ? @visible_project_ids : visible_for(*rule)
        events[:subject_type].eq(kind).and(events[:subject_id].in(ids))
      end
      conditions << events[:subject_type].eq("Workload::Action")
                                         .and(events[:subject_id].in(visible_workload_action_ids))
      if @include_moves
        conditions << events[:subject_type].eq("Projects::Project").and(events[:action].in(%w[moved_in moved_out]))
      end

      conditions.reduce(:or)
    end

    def visible_for(model, column)
      model.where(column => @visible_project_ids).select(:id).arel
    end

    # Il carico di lavoro appartiene a un team, non a un progetto: stesso criterio di
    # Workload::Action.visible_to, che è dove quella regola è scritta.
    def visible_workload_action_ids
      Workload::Action.where(team_id: @visible_team_ids).select(:id).arel
    end

    # La cronologia dei ticket è confinata ai progetti VISIBILI: `organization_id` da solo lascerebbe
    # passare i ticket di un progetto non assegnato (anti-BOLA, come fa Secrets::AuditQuery).
    def ticket_scope
      Ticketing::Event
        .where(organization_id: @organization.id)
        .where(ticket_id: Ticketing::Ticket.where(project_id: @visible_project_ids).select(:id))
        .includes(:actor, :ticket)
    end

    def permission_scope
      Authorization::Event.where(organization_id: @organization.id).includes(:actor)
    end

    # --- Filtri ---------------------------------------------------------------------------------

    def filtered(relation)
      relation = relation.where(action: @filters[:action]) if @filters[:action].present?
      relation = relation.where(actor_id: @filters[:actor_id]) if @filters[:actor_id].present?
      relation = relation.where(created_at: @filters[:from]..) if @filters[:from].present?
      relation = relation.where(created_at: ..@filters[:to]) if @filters[:to].present?
      relation
    end

    # --- Etichette ------------------------------------------------------------------------------

    # Snapshot-first: il nome inciso sulla riga resiste alla cancellazione dell'account.
    def direction = @oldest_first ? :asc : :desc

    def actor_name_for(event) = event.actor_name.presence || event.actor&.name

    def subject_label(subject)
      return nil if subject.nil?

      %i[code name title].each { |attr| return subject.public_send(attr) if subject.respond_to?(attr) }
      nil
    end

    def project_id_for(subject)
      return subject.id if subject.is_a?(Projects::Project)

      subject.project_id if subject.respond_to?(:project_id)
    end

    # Su cosa ha agito un cambio-permesso: le label sono già UMANE e snapshottate nel `data`, quindi la
    # frase resta veritiera anche se il ruolo, la persona o il team vengono poi rinominati.
    def permission_subject(data)
      data.values_at("role", "team", "account", "key").compact.first
    end
  end
end
