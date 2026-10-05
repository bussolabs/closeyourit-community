# frozen_string_literal: true

module Projects
  # Fonte di telemetria OSSERVATA: un tool (SDK/agent) che ha realmente inviato dati al progetto, con
  # l'ultima versione vista e l'ultimo istante di attività. Nasce dall'ingest (errori/metriche/log) via
  # `track!`. `tool_code` = il `sdk.name` del filo — QUALSIASI stringa: è telemetria, si registra ciò che
  # arriva (un tool ignoto compare col code grezzo). Dal CYRA-64 è l'UNICA fonte della card Monitoring
  # tools: i tool sono assunti dalle chiamate ricevute (niente più dichiarazione manuale), sempre
  # all'ultima versione vista, con la cronologia in Projects::Source::Version. Stesso upsert atomico di
  # Projects::Release#track_event!.
  class Source < ApplicationRecord
    self.table_name = "projects_sources"

    # Placeholder degli scrubber SDK: alcuni client over-matchano la chiave `name` del proprio blocco
    # `sdk` e spediscono il nome già redatto (es. "[FILTERED]"). Non è un tool reale → si scarta lato
    # server (guard in `track!`) e non lo si mostra nel presenter Projects::ToolsOverview (dati storici).
    PLACEHOLDER_CODES = %w[filtered redacted].freeze

    belongs_to :project, class_name: "Projects::Project", inverse_of: :sources
    # Cronologia versioni: una riga per ogni versione vista del tool (optin → optout). Popolata da track!.
    has_many :versions, class_name: "Projects::Source::Version", foreign_key: :source_id,
             inverse_of: :source, dependent: :destroy

    normalizes :tool_code, with: ->(value) { value.to_s.strip }
    normalizes :version, with: ->(value) { value.to_s.strip.presence }

    validates :tool_code, presence: true, uniqueness: { scope: :project_id }

    scope :recent, -> { order(last_seen_at: :desc) }

    # Upsert atomico dall'ingest: crea la fonte al primo evento e aggiorna versione/attività/contatore.
    # Una sola query (ON CONFLICT), sicura sotto concorrenza dei job. Chiave d'identità [progetto, tool].
    # Versione: last-write-wins (l'ultima presente vince; un evento senza versione non azzera quella nota).
    #
    # Coalesce sotto burst (CYRA-42): un solo upsert per [progetto, tool, versione] per finestra
    # (SOURCE_TRACK_COALESCE_INTERVAL), così un backend che emette centinaia di eventi/sec con lo stesso
    # SDK non ricontende la riga hot projects_sources ad ogni campione. La versione è nella chiave → un
    # upgrade dell'SDK usa una chiave nuova e passa SUBITO (la versione SDK resta aggiornata). Il throttle
    # usa la cache atomica (unless_exist): in produzione è cross-process (i job d'ingest girano sul
    # worker), sotto :null_store di test la write riesce sempre → nessun throttle (i test mirati usano
    # MemoryStore). Chiamata SEMPRE fuori dalla transazione del gruppo (upsert autonomo) dai Record.
    def self.track!(project:, tool_code:, version:, occurred_at:)
      code = tool_code.to_s.strip
      return if code.blank? || placeholder_code?(code)

      ver = version.to_s.strip.presence
      # Chiave di coalesce INIETTIVA: tool e versione sono stringhe ARBITRARIE di telemetria (il code è
      # "QUALSIASI stringa"), quindi un ':' letterale non deve far collidere coppie distinte (es.
      # ["a:b","c"] e ["a","b:c"] darebbero la stessa chiave concatenata) → la coppia passa da un digest.
      # project.id (UUID) resta in chiaro per leggibilità/scan.
      key = "projects:source:track:#{project.id}:#{Digest::SHA256.hexdigest([ code, ver ].to_json)}"
      # Asked locally first: a window this process already holds needs no locking write (CYRA-890).
      return if Ops::LocalGate.held?(key)
      return unless Rails.cache.write(key, true, unless_exist: true,
                                      expires_in: Projects::Constants::SOURCE_TRACK_COALESCE_INTERVAL)

      Ops::LocalGate.hold(key, expires_in: Projects::Constants::SOURCE_TRACK_COALESCE_INTERVAL)

      now = Time.current
      seen = occurred_at || now
      result = upsert_all(
        [ { project_id: project.id, tool_code: code, version: ver,
            first_seen_at: seen, last_seen_at: seen, events_count: 1,
            created_at: now, updated_at: now } ],
        unique_by: %i[project_id tool_code],
        returning: %w[id],
        on_duplicate: Arel.sql(
          "version = COALESCE(excluded.version, projects_sources.version), " \
          "events_count = projects_sources.events_count + 1, " \
          "first_seen_at = LEAST(COALESCE(projects_sources.first_seen_at, excluded.first_seen_at), excluded.first_seen_at), " \
          "last_seen_at = GREATEST(COALESCE(projects_sources.last_seen_at, excluded.last_seen_at), excluded.last_seen_at), " \
          "updated_at = excluded.updated_at"
        )
      )
      # Cronologia versioni (CYRA-64): storicizza la versione vista, se presente. Best-effort e FUORI dal
      # rescue di coalesce — un errore qui NON rilascia la finestra né rilancia, così non causa un retry
      # che ri-conterebbe events_count sulla fonte. La cronologia è un dato osservazionale secondario.
      track_version!(source_id: result.first&.fetch("id"), version: ver, seen: seen, now: now) if ver
    rescue StandardError
      # L'upsert è fallito (es. lock timeout sotto burst — proprio lo scenario conteso): rilascia la
      # finestra di coalesce, così un retry o il prossimo evento riprova SUBITO invece di restare
      # soppresso fino alla scadenza della chiave (la fonte non resterebbe non creata/aggiornata).
      if key
        Rails.cache.delete(key)
        Ops::LocalGate.release(key)
      end
      raise
    end

    # Upsert atomico [fonte, versione] della cronologia: crea la finestra alla prima comparsa e la
    # allarga ad ogni nuova occorrenza (LEAST/GREATEST). Un upgrade dell'SDK usa una chiave nuova → nuova
    # riga: la vecchia versione resta congelata al suo last_seen_at (l'optout verso la nuova). Best-effort:
    # se fallisce logga e prosegue (la cronologia non deve rompere l'ingest né gonfiare la fonte via retry).
    def self.track_version!(source_id:, version:, seen:, now:)
      return if source_id.blank?

      Version.upsert_all(
        [ { source_id: source_id, version: version, first_seen_at: seen, last_seen_at: seen,
            created_at: now, updated_at: now } ],
        unique_by: %i[source_id version],
        on_duplicate: Arel.sql(
          "first_seen_at = LEAST(projects_source_versions.first_seen_at, excluded.first_seen_at), " \
          "last_seen_at = GREATEST(projects_source_versions.last_seen_at, excluded.last_seen_at), " \
          "updated_at = excluded.updated_at"
        )
      )
    rescue StandardError => e
      Rails.logger.warn("Projects::Source version history upsert failed: #{e.class}: #{e.message}")
    end

    # Backfill one-shot (CYRA-64): semina la cronologia versioni dalle fonti GIÀ esistenti — ogni
    # projects_sources con una versione nota diventa la sua prima riga di cronologia, usando la finestra
    # di attività della fonte (first/last_seen_at, fallback su created_at per il vincolo NOT NULL). Senza,
    # dopo il deploy la cronologia delle fonti pregresse resterebbe vuota fino al prossimo ingest. Salta le
    # fonti senza versione (coerente con track!). Idempotente (ON CONFLICT DO NOTHING su [source, version]).
    # SQL puro: nessuna validazione/associazione, così la migration che lo invoca resta stabile nel tempo.
    def self.backfill_version_history!
      connection.execute(<<~SQL.squish)
        INSERT INTO projects_source_versions
          (id, source_id, version, first_seen_at, last_seen_at, created_at, updated_at)
        SELECT gen_random_uuid(), s.id, btrim(s.version),
               COALESCE(s.first_seen_at, s.last_seen_at, s.created_at),
               COALESCE(s.last_seen_at, s.first_seen_at, s.created_at),
               now(), now()
        FROM projects_sources s
        WHERE s.version IS NOT NULL AND btrim(s.version) <> ''
        ON CONFLICT (source_id, version) DO NOTHING
      SQL
    end

    # `true` se il code è un valore redatto da uno scrubber SDK (non un tool reale) → da scartare.
    # Parentesi e maiuscole insensibili: "[FILTERED]", "FILTERED", "REDACTED" ricadono tutti qui.
    def self.placeholder_code?(value)
      bare = value.to_s.strip.downcase.delete("[]").strip
      bare.present? && PLACEHOLDER_CODES.include?(bare)
    end

    # Voce del registry per il rendering (icona/colore/label); fallback generico su tool ignoto.
    def tool = Monitoring::Tool.find(tool_code) || Monitoring::Tool.new(tool_code)
  end
end
