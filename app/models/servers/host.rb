# frozen_string_literal: true

module Servers
  # Server fisico/VM monitorato: auto-registrato al primo push dell'agent (fingerprint), org-scoped.
  # Le colonne cpu_pct/mem_pct/... sono lo SNAPSHOT dell'ultimo campione (denormalizzato per la
  # fleet index); la storia vive in Servers::Sample. systemd/SMART = solo stato corrente (jsonb).
  class Host < ApplicationRecord
    belongs_to :organization,
               class_name: "Organizations::Organization",
               inverse_of: :server_hosts
    # CYRA-469 — il codice di accesso con cui questa macchina si è registrata. Opzionale: gli host
    # nati prima di questa colonna non hanno un codice attribuibile (il dato storico non esiste).
    belongs_to :enrollment_token,
               class_name: "Servers::EnrollmentToken",
               inverse_of: :hosts,
               optional: true
    has_many :samples, class_name: "Servers::Sample", foreign_key: :host_id,
             inverse_of: :host, dependent: :destroy
    has_many :container_samples, class_name: "Servers::ContainerSample", foreign_key: :host_id,
             inverse_of: :host, dependent: :destroy
    has_many :environment_links, class_name: "Connections::EnvironmentHost", foreign_key: :host_id,
             inverse_of: :host, dependent: :destroy
    # Log nativi journald (stream err/crit): append-only, cancellati con l'host via FK cascade.
    has_many :journal_entries, class_name: "Servers::Journal::Entry", foreign_key: :host_id,
             inverse_of: :host, dependent: :delete_all
    has_many :host_tokens, class_name: "Servers::HostToken", foreign_key: :host_id,
             inverse_of: :host, dependent: :destroy
    # CYRA-519 — le regole di avviso silenziate su QUESTA macchina. Vivono qui perché è dalla sua
    # scheda che si mettono e si tolgono: un silenzio che non si vede è un silenzio dimenticato.
    has_many :alerting_rule_exclusions, class_name: "Alerting::RuleHostExclusion", foreign_key: :host_id,
             inverse_of: :host, dependent: :destroy
    has_many :excluded_alerting_rules, through: :alerting_rule_exclusions, source: :rule

    has_many :actions, class_name: "Servers::Action", foreign_key: :host_id,
             inverse_of: :host, dependent: :destroy

    # Salute gestita dal sistema (workflow tecnico) → enum legittimo (rules/lookup-tables.md).
    # pending = registrato, nessun campione ancora processato. paused = escluso da staleness/alert.
    enum :status, { pending: 0, up: 1, down: 2, paused: 3 }, prefix: :status

    # CYRA-458: soglia d'allarme PER-MACCHINA delle metriche di occupazione. Mappa l'event_type della
    # regola (Alerting::Rule) alla colonna che porta l'override di QUESTA macchina: impostata → questa
    # macchina è giudicata con la sua soglia (in UI e in Alerting::Evaluate); vuota → vale il "valore di
    # partenza" della regola org (risposta al ticket). Solo cpu/mem/disco: temp e database restano org-only.
    THRESHOLD_COLUMNS = {
      "server_cpu" => :cpu_threshold,
      "server_mem" => :mem_threshold,
      "server_disk" => :disk_threshold
    }.freeze

    normalizes :name, with: ->(value) { value.to_s.strip }
    normalizes :hostname, with: ->(value) { value.to_s.strip.presence }
    # CYRA-489 — nomi che su QUESTA macchina non sono servizi: i container di compilazione e test
    # nascono e muoiono a ogni lavorazione, e segnalarli come guasti significava un avviso ogni pochi
    # minuti. Sono frammenti di nome (non espressioni regolari) perché li scrive una persona e devono
    # restare leggibili sulla scheda; il confronto è senza distinzione di maiuscole.
    IGNORED_CONTAINER_PATTERNS_MAX = 20

    normalizes :ignored_container_patterns, with: lambda { |value|
      Array(value).flat_map { |item| item.to_s.split(/[\n,]/) }.map(&:strip).compact_blank.uniq.first(IGNORED_CONTAINER_PATTERNS_MAX)
    }

    # CYRA-470 — i gruppi (etichette libere) con cui si organizza la flotta: "produzione", "staging",
    # "CI". Uno o più per macchina, scritti nel form come testo separato da virgola o a capo (come i
    # pattern container qui sopra). Etichette esatte, non frammenti: il filtro cerca il gruppo intero,
    # quindi qui basta ripulire e togliere i doppioni, senza un minimo di lunghezza.
    GROUPS_MAX = 20
    GROUP_MAX_LENGTH = 40

    normalizes :groups, with: lambda { |value|
      Array(value).flat_map { |item| item.to_s.split(/[\n,]/) }.map(&:strip).compact_blank.uniq.first(GROUPS_MAX)
    }

    validate :ignored_container_patterns_are_short
    validate :groups_within_limits

    # Il nome è di un container che questa macchina non considera un servizio?
    def ignored_container?(name)
      value = name.to_s.downcase
      ignored_container_patterns.any? { |pattern| value.include?(pattern.to_s.downcase) }
    end

    # CYRA-678 — gemello dei pattern container per le unit systemd: una unit rumorosa (oneshot che
    # fallisce per design) si esclude dagli AVVISI senza spegnere la regola per tutta la macchina.
    # Solo alerting: lo stato raccolto (elenco unit, contatore failed) resta veritiero sul pannello.
    normalizes :ignored_service_patterns, with: lambda { |value|
      Array(value).flat_map { |item| item.to_s.split(/[\n,]/) }.map(&:strip).compact_blank.uniq.first(IGNORED_CONTAINER_PATTERNS_MAX)
    }
    validate :ignored_service_patterns_are_short

    # La unit systemd è esclusa dagli avvisi di questa macchina?
    def ignored_service?(name)
      value = name.to_s.downcase
      ignored_service_patterns.any? { |pattern| value.include?(pattern.to_s.downcase) }
    end


    validates :fingerprint, presence: true, uniqueness: { scope: :organization_id }
    validates :name, presence: true
    # Percentuali di occupazione (0–100). allow_nil: nessuna soglia per-macchina = vale la regola org.
    validates :cpu_threshold, :mem_threshold, :disk_threshold,
              numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 }, allow_nil: true

    scope :ordered, -> { order(:name) }
    # Host che l'agent serve ancora: un host revocato risponde 403 al push (l'agent si ferma).
    scope :active, -> { where(revoked_at: nil) }
    # Host "silenti": up da troppo tempo senza push → CheckStaleJob li marca down.
    # `now` come bind (Time.current) → testabile con travel_to. paused/revocati esclusi.
    #
    # CYRA-649 — si misura su last_push_at, NON su last_seen_at, e le due colonne devono restare
    # separate. last_push_at è l'ora in cui la richiesta dell'agent è entrata, scritta dal controller
    # (Api::V1::Servers::SamplesController#create) col nostro orologio; last_seen_at è l'ora della
    # fotografia contenuta nel payload, scritta dall'ingest ASINCRONO con l'orologio dell'agent.
    # Giudicare la salute sulla seconda voleva dire che (a) un arretrato nella corsia dei dati
    # dichiarava giù tutta la flotta — è successo ogni notte per settimane, ~76 avvisi falsi al
    # giorno — e (b) una macchina con l'orologio indietro risultava giù per sempre.
    scope :stale, lambda { |now = Time.current|
      active.status_up.where(last_push_at: ...now - Servers::Constants::STALE_AFTER_SECONDS.seconds)
    }
    # CYRA-461 — lo stato INTERMEDIO fra attiva e spenta: raggiungibile ma silenziosa. Derivato, mai
    # persistito: è una lettura dell'età dell'ultimo push, e un campo in più andrebbe tenuto
    # allineato da qualcuno. Il caso pericoloso non è la macchina spenta — quella è segnalata — ma
    # quella che invia a singhiozzo: sembra sana e non lo è.
    #
    # Misura di proposito last_seen_at e NON last_push_at (CYRA-649): qui la domanda è «quanto è
    # vecchio il numero che sto guardando», non «la macchina risponde». Sono due domande diverse e
    # servono a due cose diverse — questa colora la scheda, `stale` fa scattare un avviso — quindi
    # nessuna delle due va riscritta in termini dell'altra.
    def silent?(now = Time.current)
      return false unless status_up?
      return false if last_seen_at.blank?

      last_seen_at < now - Servers::Constants::SILENT_AFTER_SECONDS.seconds
    end

    # Quanto è vecchio il dato che stiamo mostrando.
    def data_age(now = Time.current) = last_seen_at && (now - last_seen_at)

    # Host su cui l'agent ha trovato un database: unico filtro dell'inventario database.
    # `-> 'databases'` e non l'operatore di esistenza `?`: quel punto interrogativo collide col
    # placeholder di ActiveRecord.
    scope :with_database, -> { where("database_snapshot -> 'databases' IS NOT NULL") }

    # CYRA-470 — le macchine di un gruppo: `@>` (contiene) sull'array jsonb, col valore come bind. Un
    # host in più gruppi compare in ognuno dei suoi filtri.
    scope :in_group, ->(name) { where("servers_hosts.groups @> ?", [ name ].to_json) }

    # CYRA-470 — quante macchine ha ogni gruppo, per la barra dei gruppi dell'elenco ("produzione 6 ·
    # staging 4"). Un host in più gruppi conta in ognuno; ordinati per nome così la barra è stabile.
    # `pluck` è una sola query (solo la colonna groups) e la flotta è piccola: l'aggregazione in Ruby
    # è più leggibile di un jsonb_array_elements lato SQL e basta e avanza.
    def self.group_counts_for(relation)
      relation.pluck(:groups).flatten.tally.sort.to_h
    end

    def revoked? = revoked_at.present?

    # CYRA-245 — una persona ha autorizzato la sostituzione della sonda su questa macchina e la
    # finestra è ancora aperta: il prossimo arruolamento col codice della flotta prende il posto della
    # credenziale attuale. Fuori dalla finestra una credenziale viva non si tocca mai — è ciò che
    # rendeva possibile presentarsi al posto di una macchina altrui e lasciarla muta per sempre.
    def reenrollment_open?(now = Time.current)
      reenrollment_requested_at.present? &&
        reenrollment_requested_at > now - Servers::Constants::REENROLLMENT_WINDOW_SECONDS.seconds
    end

    # Fino a quando la riadozione resta aperta (nil se non è aperta): è il dato che la scheda mostra
    # a chi sta reinstallando, invece di un generico "hai un'ora di tempo".
    def reenrollment_expires_at
      return nil if reenrollment_requested_at.blank?

      reenrollment_requested_at + Servers::Constants::REENROLLMENT_WINDOW_SECONDS.seconds
    end

    # Soglia d'allarme per-macchina della metrica di quell'evento server, o nil se non impostata (o se
    # l'evento non ha un override per-macchina). Letta da Alerting::Evaluate e dalle viste server (CYRA-458).
    def threshold_for(event_type)
      column = THRESHOLD_COLUMNS[event_type.to_s]
      column && public_send(column)
    end

    # L'agent ha trovato un database su questa macchina (snapshot con l'elenco): gli avvisi server_db_*
    # la riguardano solo in questo caso (Alerting::Coverage.server_rules_for). Specchio per-record dello
    # scope .with_database.
    def database? = database_snapshot&.dig("databases").present?

    # CYRA-465 — questa macchina ha mai riportato la temperatura? Su VM senza sensori temp_max resta
    # nil a ogni campione: l'assenza è strutturale, non un buco temporaneo. Derivato dai campioni
    # (tutta la retention grezza) e mai cablato — un bare-metal che un giorno la esponesse la fa
    # ricomparire da sé. Nasconde il grafico e scrive nei dettagli perché il dato manca.
    def reports_temperature? = samples.where.not(temp_max: nil).exists?

    # Un'azione introdotta dopo l'agent installato sull'host verrebbe rifiutata sul posto ("tipo
    # azione non supportato"): meglio non offrirla affatto. Versione illeggibile o assente = agent
    # troppo vecchio per qualunque azione versionata.
    def supports_action?(kind)
      minimum = Servers::Action::KIND_MIN_AGENT_VERSION[kind]
      return true if minimum.nil?

      Gem::Version.new(agent_version.to_s) >= minimum
    rescue ArgumentError
      false
    end

    # Aggiornamenti che apply_security_updates NON può installare: sono quelli che restano appesi
    # dopo l'azione e che solo apply_all_updates fa sparire. nil quando un conteggio manca (agent
    # vecchio o distro non-apt): meglio non dire niente che dire un numero inventato.
    def non_security_updates
      return nil if updates_available.nil? || security_updates_available.nil?

      [ updates_available - security_updates_available, 0 ].max
    end

    # Un frammento troppo corto (una lettera) escluderebbe mezzo mondo: il rischio dichiarato nel
    # ticket è proprio un filtro largo che nasconde guasti veri.
    def ignored_container_patterns_are_short
      return if ignored_container_patterns.all? { |pattern| pattern.to_s.length >= 3 }

      errors.add(:ignored_container_patterns, :too_short)
    end

    def ignored_service_patterns_are_short
      return if ignored_service_patterns.all? { |pattern| pattern.to_s.length >= 3 }

      errors.add(:ignored_service_patterns, :too_short)
    end

    # CYRA-470 — un'etichetta spropositata è un incolla accidentale, non un gruppo: la fermo invece di
    # riempire la barra dei gruppi con una riga illeggibile.
    def groups_within_limits
      return if groups.all? { |group| group.to_s.length <= GROUP_MAX_LENGTH }

      errors.add(:groups, :too_long, count: GROUP_MAX_LENGTH)
    end
  end
end
