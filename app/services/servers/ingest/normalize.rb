# frozen_string_literal: true

module Servers
  module Ingest
    # Traduce il push dell'agent (chiavi compatte derivate da Beszel dentro `data`, chiavi leggibili
    # in `host`/`smart`) nell'hash canonico persistito. UNICO punto di traduzione del wire (il codice
    # Go derivato non rinomina nulla): testato contro la fixture condivisa agent_payload.json.
    # NON tocca il DB.
    class Normalize < ApplicationService
      # La pulizia del dato in ingresso (tetto del testo, percentuale in scala, lista cappata, istante
      # nel futuro) e la rimozione dei dati personali vivono in un punto solo e valgono per tutti i
      # canali di ingest — CYRA-735.
      include ::Ingest::Normalization
      include ::Ingest::PiiScrubbing

      Normalized = Data.define(
        :recorded_at, :agent_version, :host_attrs, :sample_attrs, :resource_pressure,
        :containers, :systemd_services, :smart_data, :failed_service_names,
        # Log nativi journald (agent >= 0.3.0). systemd_present distingue "sezione assente" (agent
        # non ha rinfrescato lo stato systemd in questo push, ~9/10 dei push) da "presente ma vuota":
        # senza, Record azzererebbe failed_services/snapshot ad ogni push senza sezione systemd.
        :journal_entries, :journal_snapshots, :systemd_present,
        # Database rilevato sull'host (agent >= 0.5.0): snapshot leggibile del blocco `database` +
        # predicato di presenza. database_present false = host senza DB (blocco assente): colonne
        # db_* NULL, nessuno snapshot, nessun alert. Presente con reachable false = DB rilevato ma
        # non sondabile (giù/auth): i sotto-oggetti possono mancare.
        :database_snapshot, :database_present,
        # Motore container interrogabile in questo push (agent)? `data.container` viaggia come null
        # quando il demone Docker è giù/illeggibile (campo nil senza omitempty), indistinguibile da
        # lista vuota. Il flag separa i due casi: Record non azzera containers_count quando manca e
        # valuta la sparizione dei container solo quando la sezione è davvero presente (CYRA-248).
        :container_present
      )

      # Vocabolari systemd dell'agent (uint8 → stringa leggibile, vedi entities/systemd).
      SYSTEMD_STATES = %w[active inactive failed activating deactivating reloading].freeze
      SYSTEMD_SUBSTATES = %w[dead running exited failed unknown].freeze
      FAILED_STATE = 2

      # Vocabolario chiuso del ruolo di replica: valore fuori lista → nil (il badge UI e la chiave
      # i18n si derivano da qui, come per gli stati systemd).
      DATABASE_ROLES = %w[primary standby].freeze

      # L'identificativo di cluster di Postgres è un intero a 64 bit (max 20 cifre): viaggia come
      # stringa perché in JSON un numero così grande perde precisione. Formato chiuso come i ruoli —
      # vedi #database_system_identifier per il perché non è testo libero.
      DATABASE_SYSTEM_IDENTIFIER_FORMAT = /\A\d{1,20}\z/

      # Oltre la tolleranza di clock-skew il recorded_at è corrotto → now (pattern Logs::Ingest).
      MAX_FUTURE_SKEW = 1.hour

      MEGABYTE = 1_048_576

      # CYRA-724 — i contatori del wire sono `unsigned` SENZA tetto nel contratto (il Go li emette da
      # uint32/uint64: restart count di un container, servizi systemd, connessioni del database,
      # core, aggiornamenti disponibili), ma qui vivono in colonne intere a 32 bit. Un valore oltre
      # il massimo non è un dato strano da tollerare come gli altri: `insert_all` solleva
      # ActiveModel::RangeError e butta via l'INTERO campione — anzi l'intero push, perché il job
      # muore prima di scrivere qualunque cosa — per un solo numero implausibile. Clamp qui, dove
      # stanno già gli altri tetti difensivi, invece di allargare colonne che nessun dato reale
      # riempirà mai: un container riavviato quattro miliardi di volte non esiste, un ingest morto sì
      # (`fixtures/valid/limits.json` porta `rc` a 4 294 967 295 e lo dimostra).
      INT32_MIN = -2_147_483_648
      INT32_MAX = 2_147_483_647

      # Tetto dei processi persistiti nel jsonb del campione: la lista arriva già top-N dall'agent.
      PROCESSES_MAX = 40

      # Le connessioni del database possono eccedere gli slot utilizzabili: la percentuale non si
      # ferma a cento, ma un valore assurdo non deve sfondare la colonna.
      DATABASE_USAGE_PCT_MAX = 999.99

      # Cap difensivi lato server (l'agent applica gli stessi cap; qui è defense-in-depth).
      JOURNAL_MAX_ENTRIES = 500
      JOURNAL_MESSAGE_MAX = 1_024
      JOURNAL_SNAPSHOT_MAX_UNITS = 10
      JOURNAL_SNAPSHOT_MAX_LINES = 50
      JOURNAL_SNAPSHOT_LINE_MAX = 512
      MICROS_PER_SECOND = 1_000_000

      # Cap difensivi sul blocco database (nomi di DB/tabelle e liste vengono da Postgres: sorgente
      # libera come journald → scrub + clamp anche qui).
      DATABASE_MAX_DATABASES = 50
      DATABASE_MAX_TOP_TABLES = 50
      DATABASE_MAX_REPLICAS = 20
      DATABASE_MAX_STATES = 20
      DATABASE_NAME_MAX = 256

      def initialize(payload:)
        @payload = payload.is_a?(Hash) ? payload : {}
      end

      def call
        Normalized.new(
          recorded_at: recorded_at,
          agent_version: @payload["agent_version"].to_s.presence,
          host_attrs: host_attrs,
          sample_attrs: sample_attrs,
          resource_pressure: resource_pressure,
          containers: containers,
          systemd_services: systemd_services,
          smart_data: smart_data,
          failed_service_names: failed_service_names,
          journal_entries: journal_entries,
          journal_snapshots: journal_snapshots,
          systemd_present: systemd_present?,
          database_snapshot: database_snapshot,
          database_present: database_present?,
          container_present: container_present?
        )
      end

      private

      def stats = @payload.dig("data", "stats").is_a?(Hash) ? @payload.dig("data", "stats") : {}
      def info = @payload.dig("data", "info").is_a?(Hash) ? @payload.dig("data", "info") : {}

      def recorded_at
        parsed = begin
          Time.zone.parse(@payload["recorded_at"].to_s)
        rescue ArgumentError
          nil
        end
        clamp_future(parsed, skew: MAX_FUTURE_SKEW) || Time.current
      end

      # Statici della macchina (chiavi leggibili, struct nostra dell'agent).
      def host_attrs
        host = @payload["host"].is_a?(Hash) ? @payload["host"] : {}
        {
          hostname: host["hostname"].to_s.presence,
          kernel: host["kernel"].to_s.presence,
          cores: int32(host["cores"]),
          threads: int32(host["threads"]),
          cpu_model: host["cpu_model"].to_s.presence,
          os_name: host["os_name"].to_s.presence,
          arch: host["arch"].to_s.presence,
          memory_total_bytes: host["memory_total"]&.to_i,
          # reboot_required: bool (false valido, non compattato); assente (agent vecchio) → default.
          reboot_required: host["reboot_required"],
          # updates_available: -1 dall'agent = sconosciuto → nil (la UI mostra "n/d", non "0").
          updates_available: normalize_updates(host["updates_available"]),
          # security_updates_available (agent ≥ 0.8.0): sottoinsieme installabile da
          # apply_security_updates. Assente (agent vecchio) → compact lo toglie e il valore resta
          # quello noto: "sconosciuto" non è "zero di sicurezza".
          security_updates_available: normalize_updates(host["security_updates_available"])
        }.compact
      end

      def normalize_updates(value)
        return nil unless value.is_a?(Numeric) && value >= 0

        value.to_i.clamp(0, INT32_MAX)
      end

      # Intero del wire riportato dentro la colonna che lo ospita: assente resta assente (nil), mai
      # zero — "non lo so" e "zero" sono due cose diverse in tutto questo dominio.
      def int32(value)
        value&.to_i&.clamp(INT32_MIN, INT32_MAX)
      end

      # Hot columns del campione + payload di dettaglio.
      def sample_attrs
        load_avg = Array(stats["la"].presence || info["la"])
        {
          cpu_pct: (stats["cpu"] || info["cpu"]).to_f.round(2),
          mem_pct: (stats["mp"] || info["mp"])&.to_f&.round(2),
          disk_pct: (stats["dp"] || info["dp"])&.to_f&.round(2),
          gpu_pct: gpu_usage_pct,
          gpu_watt: gpu_total_watt,
          load_1: load_avg[0]&.to_f, load_5: load_avg[1]&.to_f, load_15: load_avg[2]&.to_f,
          net_sent_bytes: Array(stats["b"])[0]&.to_i,
          net_recv_bytes: Array(stats["b"])[1]&.to_i,
          disk_read_bytes: Array(stats["dio"])[0]&.to_i,
          disk_write_bytes: Array(stats["dio"])[1]&.to_i,
          uptime_seconds: info["u"]&.to_i,
          temp_max: temp_max,
          services_total: int32(Array(info["sv"])[0]),
          services_failed: int32(Array(info["sv"])[1]),
          # Hot columns del database (chart + soglie). Host senza DB → tutte nil (colonne nullable).
          db_up: database_snapshot&.dig("reachable"),
          db_connections: database_snapshot&.dig("connections", "total"),
          db_connection_usage_pct: database_connection_usage_pct,
          db_replication_lag_seconds: database_snapshot&.dig("replication", "lag_seconds"),
          data_volume_disk_pct: resource_pressure.dig("data_volume_disk", "pct"),
          inode_pct: resource_pressure.dig("inode", "pct"),
          payload: detail_payload
        }
      end

      def temp_max
        temps = stats["t"]
        return info["dt"]&.to_f if !temps.is_a?(Hash) || temps.empty?

        temps.values.map(&:to_f).max
      end

      # CYRA-703 — l'uso della scheda più carica. Deriva dal payload GPU e non da info["g"] perché
      # l'agent marca quel campo omitempty (system.go:161): a 0% non lo manda affatto, e la colonna
      # finiva per dire "nessun dato" quando il dato era zero. Il fallback su info["g"] resta per gli
      # agent che mandano la sintesi ma non il dettaglio.
      def gpu_usage_pct
        usi = gpu_entries.filter_map { |gpu| gpu["u"]&.to_f }
        return info["g"]&.to_f&.round(2) if usi.empty?

        usi.max.round(2)
      end

      # I watt li assorbe la macchina, non la singola scheda: con due GPU il numero che conta è la somma.
      def gpu_total_watt
        watt = gpu_entries.filter_map { |gpu| gpu["p"]&.to_f }
        return nil if watt.empty?

        watt.sum.round(2)
      end

      def gpu_entries
        gpus = stats["g"]
        return [] unless gpus.is_a?(Hash)

        gpus.values.select { |gpu| gpu.is_a?(Hash) }
      end

      # Dettaglio jsonb del campione (tutto ciò che non è hot column; niente systemd/SMART).
      def detail_payload
        {
          "temps" => stats["t"],
          "extra_fs" => stats["efs"],
          "gpu" => stats["g"],
          "cpu_breakdown" => stats["cpub"],
          "cores_usage" => stats["cpus"],
          "per_nic" => stats["ni"],
          "battery" => stats["bat"],
          "disk_io_stats" => stats["dios"],
          "mem" => { "total_gb" => stats["m"], "used_gb" => stats["mu"], "buff_cache_gb" => stats["mb"],
                     "zfs_arc_gb" => stats["mz"] }.compact.presence,
          "swap" => { "total_gb" => stats["s"], "used_gb" => stats["su"] }.compact.presence,
          "disk" => { "total_gb" => stats["d"], "used_gb" => stats["du"],
                      "inode_total" => stats["it"], "inode_used" => stats["iu"],
                      "inode_pct" => stats["ip"] }.compact.presence,
          # Dettaglio database (per-stato, per-DB, top-tabelle, replicas, versione/engine/max): il
          # campione porta lo stesso snapshot denormalizzato sull'host, così la storia è ricostruibile.
          "database" => database_snapshot,
          "processes" => processes
        }.compact
      end

      # Top processi per CPU/memoria (CYAG-14, chiave compatta `proc`: p/n/c/m). Lista già top-N e
      # ordinata dall'agent; il tetto difensivo evita che un agent malconcio gonfi il jsonb.
      def processes
        rows(stats["proc"], PROCESSES_MAX) do |item|
          next unless item.is_a?(Hash)

          name = item["n"].to_s
          next if name.blank?

          { "pid" => item["p"].to_i, "name" => name,
            "cpu_pct" => item["c"].to_f, "mem_bytes" => item["m"].to_i }
        end
      end

      # Container (chiavi compatte: n/c/m/b + stato runtime aggiunto dal nostro agent). Mem agent = MB.
      # `im` (idle_managed) arriva solo dagli agent aggiornati: assente = false, cioè il default
      # prudente — un container che sparisce resta un guasto finché non ci dicono il contrario.
      def containers
        list = @payload.dig("data", "container")
        return [] unless list.is_a?(Array)

        list.filter_map do |item|
          next unless item.is_a?(Hash) && item["n"].to_s.present?

          {
            container_id: clean_text(item["id"], 64).presence,
            name: item["n"].to_s,
            image: normalize_image(item["img"]),
            status: item["st"].to_s.presence,
            health: item["h"].to_i.clamp(0, 3),
            idle_managed: item["im"] == true,
            # Gli agent precedenti elencavano soltanto i container running e non mandavano `run`:
            # assente significa quindi true, non false.
            running: item.key?("run") ? item["run"] == true : true,
            restart_count: item["rc"].to_i.clamp(0, INT32_MAX),
            started_at: container_started_at(item["sa"]),
            oom_killed: item["oom"] == true,
            cpu_pct: item["c"]&.to_f&.round(2),
            mem_bytes: item["m"] ? (item["m"].to_f * MEGABYTE).round : nil,
            net_sent_bytes: Array(item["b"])[0]&.to_i,
            net_recv_bytes: Array(item["b"])[1]&.to_i
          }
        end
      end

      # Gemello di systemd_present?: distingue "sezione container assente" (motore Docker non
      # interrogabile → data.container null) da "presente ma vuota" (nessun container in esecuzione).
      def container_present? = @payload.dig("data", "container").is_a?(Array)

      # CYRA-464 — l'indirizzo di provenienza arrivava col prefisso del registro RIPETUTO
      # (`registry.esempio.it/registry.esempio.it/org/app`, `ghcr.io/ghcr.io/…`): una doppia
      # concatenazione fra agent e serializzatore. Si ripulisce QUI, alla fonte: farlo solo in vista
      # maschererebbe il difetto e lascerebbe sporchi i dati storici.
      def normalize_image(value)
        image = value.to_s.strip
        return nil if image.blank?

        segments = image.split("/")
        segments.shift while segments.size > 1 && segments.first == segments[1]
        segments.join("/")
      end

      def container_started_at(value)
        Time.zone.parse(value.to_s) if value.present?
      rescue ArgumentError
        nil
      end

      # Snapshot della risorsa peggiore per ciascun alert. Il campione conserva comunque l'intera
      # mappa extra_fs; questo indice piccolo serve al contenuto della notifica per nominare mount e
      # percentuale senza cercare a posteriori in un push successivo.
      def resource_pressure
        return @resource_pressure if defined?(@resource_pressure)

        @resource_pressure = {
          "data_volume_disk" => highest_data_volume_disk_pressure,
          "inode" => highest_inode_pressure
        }.compact
      end

      def highest_data_volume_disk_pressure
        filesystem_pressure_candidates.filter_map do |key, item|
          total = item["d"]&.to_f
          used = item["du"]&.to_f
          next if total.nil? || total <= 0 || used.nil?

          filesystem_pressure(key, item, ((used / total) * 100).round(2))
        end.max_by { |entry| entry["pct"] }
      end

      def highest_inode_pressure
        candidates = filesystem_pressure_candidates.filter_map do |key, item|
          pct = numeric_percentage(item["ip"])
          filesystem_pressure(key, item, pct) if pct
        end
        root_pct = numeric_percentage(stats["ip"])
        candidates << { "name" => "root", "mountpoint" => "/", "pct" => root_pct } if root_pct
        candidates.max_by { |entry| entry["pct"] }
      end

      def filesystem_pressure_candidates
        extra = stats["efs"]
        extra.is_a?(Hash) ? extra.filter { |_key, item| item.is_a?(Hash) } : {}
      end

      def filesystem_pressure(key, item, pct)
        {
          "name" => clean_text(item["n"].presence || key, DATABASE_NAME_MAX),
          "mountpoint" => clean_text(item["mp"].presence || key, DATABASE_NAME_MAX),
          "pct" => pct.clamp(0, 100)
        }
      end

      # Stato corrente systemd (leggibile) per il jsonb dell'host.
      def systemd_services
        list = @payload.dig("data", "systemd")
        return [] unless list.is_a?(Array)

        list.filter_map do |item|
          next unless item.is_a?(Hash) && item["n"].to_s.present?

          {
            "name" => item["n"].to_s,
            "state" => SYSTEMD_STATES[item["s"].to_i] || "inactive",
            "sub" => SYSTEMD_SUBSTATES[item["ss"].to_i] || "unknown",
            "cpu_pct" => item["c"]&.to_f,
            "mem_bytes" => item["m"]&.to_i,
            "cpu_peak_pct" => item["cp"]&.to_f,
            "mem_peak_bytes" => item["mp"]&.to_i
          }
        end
      end

      def failed_service_names
        list = @payload.dig("data", "systemd")
        return [] unless list.is_a?(Array)

        list.filter_map { |item| item["n"].to_s if item.is_a?(Hash) && item["s"].to_i == FAILED_STATE }
      end

      # SMART corrente (leggibile) per il jsonb dell'host. Gli attributes verbosi non si persistono.
      def smart_data
        smart = @payload["smart"]
        return {} unless smart.is_a?(Hash)

        smart.each_with_object({}) do |(device, item), acc|
          next unless item.is_a?(Hash)

          acc[device.to_s] = {
            "model" => item["mn"].to_s.presence,
            "serial" => item["sn"].to_s.presence,
            "firmware" => item["fv"].to_s.presence,
            "capacity_bytes" => item["c"]&.to_i,
            "status" => item["s"].to_s.presence,
            "device" => item["dn"].to_s.presence,
            "type" => item["dt"].to_s.presence,
            "temp" => item["t"]&.to_f
          }.compact
        end
      end

      # La sezione systemd arriva solo quando l'agent ha rinfrescato lo stato (worker ogni 10min →
      # ~1 push su 10); distinguere assente (nil) da presente-ma-vuota evita che Record azzeri lo
      # stato systemd/snapshot ai push senza sezione.
      def systemd_present?
        @payload.dig("data", "systemd").is_a?(Array)
      end

      def journal
        @payload["journal"].is_a?(Hash) ? @payload["journal"] : {}
      end

      # Stream journald priority <= err/crit. Scarta item senza cursore (idempotenza) o message vuoto.
      def journal_entries
        rows(journal["entries"], JOURNAL_MAX_ENTRIES) do |item|
          next unless item.is_a?(Hash)

          cursor = item["c"].to_s
          message = clean_free_text(item["m"], JOURNAL_MESSAGE_MAX)
          next if cursor.blank? || message.blank?

          {
            cursor: cursor,
            occurred_at: micros_to_time(item["t"]),
            priority: item["p"].to_i.clamp(0, 7),
            unit: item["u"].to_s.presence,
            message: message
          }
        end || []
      end

      # Snapshot journalctl -u <unit> per le unit systemd failed, keyed per nome wire (== systemd `n`).
      def journal_snapshots
        snaps = journal["snapshots"]
        return {} unless snaps.is_a?(Hash)

        snaps.first(JOURNAL_SNAPSHOT_MAX_UNITS).each_with_object({}) do |(unit, snap), acc|
          next unless unit.to_s.present? && snap.is_a?(Hash)

          lines = Array(snap["lines"]).first(JOURNAL_SNAPSHOT_MAX_LINES)
                                      .map { |line| clean_free_text(line, JOURNAL_SNAPSHOT_LINE_MAX) }
          acc[unit.to_s] = { "captured_at" => snapshot_time(snap["t"]), "lines" => lines }
        end
      end

      # µs epoch → Time (unità nota: niente euristica ms di Logs::Ingest). Clamp future come recorded_at.
      def micros_to_time(micros)
        return Time.current unless micros.to_s.match?(/\A\d+\z/)

        clamp_future(Time.zone.at(micros.to_i / MICROS_PER_SECOND.to_f), skew: MAX_FUTURE_SKEW)
      end

      # captured_at dello snapshot è in secondi (contratto). ISO8601 nel jsonb per leggibilità.
      def snapshot_time(seconds)
        return nil unless seconds.to_s.match?(/\A\d+\z/)

        Time.zone.at(seconds.to_i).iso8601
      end

      # Blocco `database` (agent >= 0.5.0): chiavi LEGGIBILI top-level come `host`/`smart`, fuori da
      # `data`. ASSENTE = host senza database (il collector Postgres non si attiva, o è fallito e
      # l'agent ha omesso il campo) → nessuna colonna db_*, nessuno snapshot, nessun alert.
      def database_present? = @payload["database"].is_a?(Hash)

      # Snapshot leggibile e cappato dell'intero blocco: unico punto di traduzione, riusato per le hot
      # columns del campione, per il dettaglio jsonb e per lo snapshot sull'host. nil se il blocco manca.
      # reachable false = DB rilevato ma non sondabile: i sotto-oggetti mancano e si compattano via.
      def database_snapshot
        return @database_snapshot if defined?(@database_snapshot)

        @database_snapshot = build_database_snapshot
      end

      def build_database_snapshot
        return nil unless database_present?

        block = @payload["database"]
        {
          "engine" => clean_text(block["engine"], DATABASE_NAME_MAX).presence,
          # Solo un booleano esplicito conta: assente/malformato → nil (sconosciuto), MAI false —
          # un payload monco non deve far scattare l'alert di database down.
          "reachable" => database_boolean(block["reachable"]),
          "version" => clean_text(block["version"], DATABASE_NAME_MAX).presence,
          "role" => database_role(block["role"]),
          "system_identifier" => database_system_identifier(block["system_identifier"]),
          "connections" => database_connections(block["connections"]),
          "replication" => database_replication(block["replication"]),
          "databases" => database_sizes(block["databases"]),
          "top_tables" => database_top_tables(block["top_tables"])
        }.compact
      end

      def database_boolean(value) = [ true, false ].include?(value) ? value : nil

      def database_role(value) = DATABASE_ROLES.include?(value.to_s) ? value.to_s : nil

      # Identificativo del cluster (agent >= 0.6.0): identico sul primary e sulle sue repliche, è il
      # legame certificato che l'inventario database usa per riconoscere le copie. Vocabolario
      # controllato come `role`, non testo libero: è un intero a 64 bit e nient'altro lo è. Un valore
      # fuori formato — un "unknown" scritto uguale su macchine scollegate — diventerebbe una falsa
      # chiave di cluster e le unirebbe; meglio assente, così si torna a dedurre come prima.
      def database_system_identifier(value)
        text = value.to_s.strip
        text.match?(DATABASE_SYSTEM_IDENTIFIER_FORMAT) ? text : nil
      end

      # Conteggio connessioni: totale + tetto (max_connections), slot riservati e ripartizione (chiavi
      # libere di pg_stat_activity → scrub + cap).
      def database_connections(raw)
        return nil unless raw.is_a?(Hash)

        by_state = raw["by_state"]
        states = if by_state.is_a?(Hash)
          by_state.first(DATABASE_MAX_STATES)
                  .to_h { |state, count| [ clean_text(state, DATABASE_NAME_MAX), count.to_i ] }
        end
        { "total" => int32(raw["total"]), "max" => int32(raw["max"]),
          "reserved" => int32(raw["reserved"]), "by_state" => states.presence }.compact.presence
      end

      def database_connection_usage_pct
        connections = database_snapshot&.dig("connections")
        return nil unless connections.is_a?(Hash)

        usable = connections["max"].to_i - connections["reserved"].to_i
        return nil if usable <= 0 || connections["total"].nil?

        # Le connessioni possono eccedere gli slot utilizzabili: il tetto qui non è cento.
        numeric_percentage((connections["total"].to_f / usable) * 100, max: DATABASE_USAGE_PCT_MAX)
      end

      # Replica: streaming attivo, lag in secondi (può mancare → nil: "sconosciuto", non zero) e
      # l'elenco delle repliche viste dal primary.
      def database_replication(raw)
        return nil unless raw.is_a?(Hash)

        {
          "streaming" => database_boolean(raw["streaming"]),
          "lag_seconds" => raw["lag_seconds"]&.to_f,
          "replicas" => database_replicas(raw["replicas"])
        }.compact.presence
      end

      def database_replicas(list)
        rows(list, DATABASE_MAX_REPLICAS) do |item|
          next unless item.is_a?(Hash)

          { "client" => clean_text(item["client"], DATABASE_NAME_MAX).presence,
            "state" => clean_text(item["state"], DATABASE_NAME_MAX).presence }.compact.presence
        end
      end

      def database_sizes(list)
        database_rows(list, DATABASE_MAX_DATABASES) { |item| { "name" => clean_text(item["name"], DATABASE_NAME_MAX) } }
      end

      def database_top_tables(list)
        database_rows(list, DATABASE_MAX_TOP_TABLES) do |item|
          { "database" => clean_text(item["database"], DATABASE_NAME_MAX).presence,
            "name" => clean_text(item["name"], DATABASE_NAME_MAX) }.compact
        end
      end

      # Righe "nome + dimensione" (database e tabelle): scarta gli item senza nome, cappa la lista.
      def database_rows(list, cap)
        rows(list, cap) do |item|
          next unless item.is_a?(Hash) && item["name"].to_s.present?

          yield(item).merge("size_bytes" => item["size_bytes"]&.to_i).compact
        end
      end

      # CYRA-735 — testo scritto da esseri umani che arriva dai log di sistema della macchina: la
      # sorgente più libera del prodotto, e fino a ora l'unica del tutto priva di redazione. Ci finisce
      # dentro di tutto (un indirizzo col token nella query, una riga di configurazione con la
      # password), quindi vale la stessa policy dei canali errori e log. Prima si ripara e si taglia,
      # poi si redige: la redazione può allungare la riga — il valore sensibile diventa un segnaposto
      # più lungo — e il tetto va riapplicato dopo. L'ordine non è invertibile anche per un secondo
      # motivo: la redazione lavora con una regex, e su byte non validi UTF-8 solleverebbe.
      def clean_free_text(raw, max)
        scrub_message(clean_text(raw, max))[0, max].to_s
      end
    end
  end
end
