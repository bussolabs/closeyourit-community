# frozen_string_literal: true

module Alerting
  # CYRA-477: copertura di un evento PROJECT-SCOPED (cron_missed / uptime_*) sulle sue entità (monitor
  # cron o uptime). Conta quante hanno ALMENO una regola abilitata che le avviserebbe e quante restano
  # scoperte — la classe di guasti che il ticket ha reso visibile: un cron "Mancato" per giorni senza
  # che nessuna regola potesse scattare.
  #
  # Resolver scope→entità IDENTICO ad Alerting::Evaluate#matching_rules (+ environment_match?): una
  # regola copre un'entità quando il suo scope la contiene — project_id nil = tutti i progetti,
  # environment_id nil = tutti gli ambienti. Read-only e senza N+1: una query per le regole, una per
  # le entità (pluck delle sole coppie di scope). Gli eventi org-scoped (server_*/agents_*) NON passano
  # di qui: là una regola qualunque copre già tutta l'org (nessuna nozione di entità scoperta).
  class Coverage
    Report = Data.define(:total, :covered, :uncovered) do
      def any_uncovered? = uncovered.positive?
      def all_covered? = total.positive? && uncovered.zero?
    end

    # CYRA-476: le entità che UNA regola sorveglia oggi. `kind` dice di che cosa si tratta (:monitors,
    # :cron_monitors, :projects, oppure :organization per gli eventi org-scoped che coprono tutto senza
    # una lista puntuale); `total` è il conteggio pieno (aggregato SQL), `records` un campione limitato.
    EntityCoverage = Data.define(:kind, :total, :records) do
      def any? = total.positive?
    end

    # Quanti record al massimo materializzare per la lista del pannello (il conteggio resta pieno): con
    # scope larghi la lista non deve caricare migliaia di righe (il "matching costoso" citato dal ticket).
    LISTED_LIMIT = 50

    # CYRA-458: gli eventi org-scoped che riguardano una macchina della flotta. Derivati dall'enum (server_*),
    # meno i tre del database — che riguardano solo gli host su cui l'agent ha trovato un database.
    SERVER_EVENT_TYPES = Alerting::Rule.event_types.keys.select { |type| type.start_with?("server_") }.freeze
    SERVER_DB_EVENT_TYPES = %w[
      server_db_down server_db_connections server_db_connection_usage server_replication_lag
      server_replication_down server_replication_up
    ].freeze

    # entities: relation di monitor che espone project_id ed environment_id (es. visible.cron_monitors).
    def self.for(organization:, event_type:, entities:)
      rule_scopes = Alerting::Rule.enabled
                                  .where(organization_id: organization.id, event_type:)
                                  .pluck(:project_id, :environment_id)
      pairs = entities.reorder(nil).pluck(:project_id, :environment_id)
      total = pairs.size
      covered = pairs.count { |project_id, environment_id| covered?(rule_scopes, project_id, environment_id) }
      Report.new(total:, covered:, uncovered: total - covered)
    end

    # CYRA-476 — verso "monitor → regole": le regole ABILITATE che avviserebbero QUESTO monitor per
    # l'evento dato (default uptime_down = "il sito cade", il rischio che il ticket rende visibile). È lo
    # stesso predicato di covered?/matching_rules materializzato in SQL: project_id nil = tutti i progetti,
    # environment_id nil = tutti gli ambienti. Preload dei canali per il pannello (nessun N+1).
    def self.rules_for(monitor:, event_type: :uptime_down)
      Alerting::Rule.enabled
                    .where(organization_id: monitor.project.organization_id, event_type:)
                    .where("project_id IS NULL OR project_id = ?", monitor.project_id)
                    .where("environment_id IS NULL OR environment_id = ?", monitor.environment_id)
                    .includes(:channels)
                    .ordered
    end

    # CYRA-458 — verso "macchina → regole che la avvisano": le regole server_* abilitate dell'org che
    # riguardano QUESTO host. Org-scoped (Evaluate#matching_org_rules ignora project/environment): una regola
    # qualsiasi copre già tutta l'org, quindi la lista è tutte le server_* abilitate — meno gli eventi del
    # database sugli host senza database (non li riguarderanno mai). Preload dei canali per il pannello (no N+1).
    def self.server_rules_for(host)
      event_types = SERVER_EVENT_TYPES.dup
      event_types -= SERVER_DB_EVENT_TYPES unless host.database?
      Alerting::Rule.enabled
                    .where(organization_id: host.organization_id, event_type: event_types)
                    .includes(:channels)
                    .ordered
    end

    # CYRA-458: { rule_id => Time } dell'ULTIMO avviso che ciascuna di quelle regole ha recapitato SU QUESTO
    # host (subject = host). Una query aggregata (no N+1); le regole mai scattate restano fuori dalla mappa.
    def self.last_triggered_for(host, rule_ids)
      return {} if rule_ids.blank?

      Alerting::Notification
        .where(subject_type: "Servers::Host", subject_id: host.id, rule_id: rule_ids)
        .group(:rule_id).maximum(:created_at)
    end

    # CYRA-476 — verso "regola → cose coperte": le entità che questa regola sorveglia oggi. Gli eventi
    # org-scoped (server_*/agents_*/workload_*) coprono l'intera org senza una lista puntuale (una regola
    # qualsiasi li copre già). Gli altri sono project-scoped: uptime_* → i monitor, cron_missed → i cron,
    # ogni altro (errori/log/metriche/idee/dataset/analytics) → i progetti. `total` è aggregato, la lista
    # è limitata (LISTED_LIMIT) contro gli scope larghi.
    def self.entities_for(rule)
      return EntityCoverage.new(kind: :organization, total: 1, records: []) if Alerting::Rule.org_scoped_event?(rule.event_type)

      kind, scope = scope_for(rule)
      EntityCoverage.new(kind:, total: scope.count, records: scope.limit(LISTED_LIMIT).to_a)
    end

    # (kind, relation già ristretta allo scope della regola). Monitor e cron hanno environment_id → il
    # filtro d'ambiente si applica; i progetti no (l'ambiente filtra gli eventi, non il progetto stesso).
    def self.scope_for(rule)
      org = rule.organization
      if rule.event_type.to_s.start_with?("uptime_")
        [ :monitors, scoped(Uptime::Monitor.where(project_id: org.projects.select(:id))
                                            .includes(:project, :environment).order(:name), rule, environment: true) ]
      elsif rule.event_cron_missed?
        [ :cron_monitors, scoped(Crons::Monitor.where(project_id: org.projects.select(:id))
                                                .includes(:project).order(:name), rule, environment: true) ]
      else
        [ :projects, scoped(org.projects.order(:name), rule, environment: false) ]
      end
    end
    private_class_method :scope_for

    def self.scoped(relation, rule, environment:)
      relation = relation.where(project_id: rule.project_id) if rule.project_id
      relation = relation.where(environment_id: rule.environment_id) if environment && rule.environment_id
      relation
    end
    private_class_method :scoped

    # Una regola con scope (rule_project, rule_environment) copre l'entità (project, environment) se
    # rule_project è nil o combacia E rule_environment è nil o combacia — la stessa condizione di
    # matching_rules ("project_id IS NULL OR project_id = ?") + environment_match?.
    def self.covered?(rule_scopes, project_id, environment_id)
      rule_scopes.any? do |rule_project, rule_environment|
        (rule_project.nil? || rule_project == project_id) &&
          (rule_environment.nil? || rule_environment == environment_id)
      end
    end
    private_class_method :covered?
  end
end
