# frozen_string_literal: true

module Servers
  # Campione di sistema immutabile (1/min per host): hot columns tipizzate per i chart, dettaglio
  # (temps per sensore, extra fs, gpu, per-nic, ...) nel payload jsonb. Idempotente per
  # [host, recorded_at] (unique index): il retry dell'agent non duplica.
  class Sample < ApplicationRecord
    # CYRA-750 — la tabella è divisa a fette mensili su `recorded_at`: da qui la chiave primaria
    # riportata a `id` e il gemello per la scrittura in blocco.
    include PartitionedTable

    belongs_to :host, class_name: "Servers::Host", inverse_of: :samples
    belongs_to :organization, class_name: "Organizations::Organization"

    validates :recorded_at, presence: true
    validates :cpu_pct, presence: true

    # Finestre del selettore chart: stesso vocabolario di Metrics::Group/Uptime::Monitor.
    RANGES = { "30m" => 30.minutes, "24h" => 24.hours, "7d" => 7.days, "30d" => 30.days }.freeze
    DEFAULT_RANGE = "24h"

    BUCKETS = {
      "30m" => { count: 30, interval: "1 minute",   seconds: 60 },
      "24h" => { count: 48, interval: "30 minutes", seconds: 1_800 },
      "7d"  => { count: 56, interval: "3 hours",     seconds: 10_800 },
      "30d" => { count: 30, interval: "1 day",       seconds: 86_400 }
    }.freeze

    def self.range_duration(key) = RANGES.fetch(key, RANGES[DEFAULT_RANGE])
    def self.bucket_config(range) = BUCKETS.fetch(range, BUCKETS[DEFAULT_RANGE])

    # CYRA-465 — esiste nell'organizzazione almeno una macchina che riporta la temperatura? Regola la
    # colonna dell'elenco, la sua chiave di ordinamento e l'evento di avviso: senza un solo sensore in
    # tutta la flotta sono spazio e scelte per un dato che non arriverà (su VM Hetzner i sensori non
    # sono esposti). Derivato dai campioni, mai cablato. L'indice parziale index_servers_samples_temp_
    # reported rende l'EXISTS immediato anche nel caso NORMALE in cui nessuno la espone.
    def self.temperature_reported?(organization)
      where(organization: organization).where.not(temp_max: nil).exists?
    end

    # Finestra da proporre all'apertura del dettaglio host: si apre piena, non dominata dal vuoto.
    # La retention grezza (30g) supera la 24h di default, ma un host appena arrivato ha solo minuti
    # di storia: 24h risulterebbe quasi tutta "non misurato" e si leggerebbe come macchina ferma
    # (CYRA-457). Regola: la finestra più lunga che non parte prima del PRIMO campione (≤ span) e
    # che raggiunge l'ULTIMO (≥ gap). Il vincolo su gap evita che un host muto con dati vecchi apra
    # su un range breve tutto DOPO gli ultimi dati, quindi vuoto (CYRA-457 review): in quel caso (o
    # se lo span è più corto del range minimo) si prende la più corta finestra che arriva ai dati.
    # Nessun campione → DEFAULT_RANGE: il vuoto è legittimo e lo dichiara la traccia tratteggiata.
    # Una MIN/MAX sull'indice (host_id, recorded_at), niente aggregazione: costo trascurabile.
    def self.default_range_for(host_ids, now = Time.current)
      ids = Array(host_ids).uniq
      return DEFAULT_RANGE if ids.blank?

      window_start = now - range_duration(RANGES.keys.last)
      first, last = where(host_id: ids, recorded_at: window_start..now)
                    .pick(Arel.sql("MIN(recorded_at)"), Arel.sql("MAX(recorded_at)"))
      return DEFAULT_RANGE if first.nil?

      span = (now - first).to_i
      gap  = (now - last).to_i

      chosen = RANGES.select { |_key, duration| duration.to_i <= span }.keys.last
      if chosen.nil? || RANGES.fetch(chosen).to_i < gap
        chosen = RANGES.select { |_key, duration| duration.to_i >= gap }.keys.first
      end
      chosen
    end

    # GB occupati davvero, medi sul blocco. Non derivabili dalla percentuale: quella è una frazione
    # del totale di OGGI, e dopo un resize di RAM o disco rileggerebbe la storia sul taglio nuovo.
    # Il valore vive nel payload perché non è una hot column; il guard su jsonb_typeof evita che un
    # agent che manda una stringa al posto di un numero faccia esplodere il cast dell'intera query.
    # SQL scritto per esteso, una costante per metrica: generarlo interpolando la chiave fa scattare
    # il check SQL injection di Brakeman (`scan_ruby` rosso), e un frammento SQL costruito a runtime
    # non vale la riga risparmiata.
    MEM_USED_GB_AVG = Arel.sql(
      "AVG(CASE WHEN jsonb_typeof(payload->'mem'->'used_gb') = 'number' " \
      "THEN (payload->'mem'->>'used_gb')::float END)"
    ).freeze
    DISK_USED_GB_AVG = Arel.sql(
      "AVG(CASE WHEN jsonb_typeof(payload->'disk'->'used_gb') = 'number' " \
      "THEN (payload->'disk'->>'used_gb')::float END)"
    ).freeze

    # CYRA-703 — la ripartizione della CPU vive nel payload come array [user, system, iowait, steal,
    # idle] (agent: Stats#CpuBreakdown). Indice numerico LETTERALE in ogni costante, mai interpolato.
    CPU_USER_AVG = Arel.sql(
      "AVG(CASE WHEN jsonb_typeof(payload->'cpu_breakdown'->0) = 'number' " \
      "THEN (payload->'cpu_breakdown'->>0)::float END)"
    ).freeze
    CPU_SYSTEM_AVG = Arel.sql(
      "AVG(CASE WHEN jsonb_typeof(payload->'cpu_breakdown'->1) = 'number' " \
      "THEN (payload->'cpu_breakdown'->>1)::float END)"
    ).freeze
    CPU_IOWAIT_AVG = Arel.sql(
      "AVG(CASE WHEN jsonb_typeof(payload->'cpu_breakdown'->2) = 'number' " \
      "THEN (payload->'cpu_breakdown'->>2)::float END)"
    ).freeze
    CPU_STEAL_AVG = Arel.sql(
      "AVG(CASE WHEN jsonb_typeof(payload->'cpu_breakdown'->3) = 'number' " \
      "THEN (payload->'cpu_breakdown'->>3)::float END)"
    ).freeze

    # Aggregati per blocco temporale, per N host in 1 query (date_bin Postgres, niente N+1) —
    # stesso schema di Metrics::Group.buckets_for. Ritorna
    # { host_id => [ {count:, at:, cpu:, mem:, disk:, temp:, mem_gb:, disk_gb:, net_out:, net_in:,
    #                 db_conn:, db_conn_max:, db_lag:, gpu:, gpu_watt:, cpu_user:, cpu_system:,
    #                 cpu_iowait:, cpu_steal:}, ... count ] }
    # ordinato vecchio→nuovo; i blocchi senza campioni restano count: 0 e valori nil.
    # `at:` = istante d'inizio del blocco (asse X / finestra oraria del tooltip in vista).
    # db_conn/db_conn_max/db_lag restano nil sugli host senza database (colonne NULL).
    # mem_gb/disk_gb restano nil sui campioni di agent che non mandano il dettaglio.
    def self.buckets_for(host_ids, range, now = Time.current)
      cfg = bucket_config(range)
      ids = Array(host_ids).uniq
      return {} if ids.blank?

      since = now - (cfg[:count] * cfg[:seconds])
      conn = connection
      bin = "date_bin(#{conn.quote(cfg[:interval])}::interval, recorded_at, #{conn.quote(since)}::timestamptz)"
      rows = where(host_id: ids, recorded_at: since...now)
             .group(Arel.sql("host_id"), Arel.sql(bin))
             .pluck(Arel.sql("host_id"), Arel.sql(bin), Arel.sql("COUNT(*)"),
                    Arel.sql("AVG(cpu_pct)"), Arel.sql("AVG(mem_pct)"), Arel.sql("AVG(disk_pct)"),
                    Arel.sql("MAX(temp_max)"), MEM_USED_GB_AVG, DISK_USED_GB_AVG,
                    Arel.sql("SUM(net_sent_bytes)"), Arel.sql("SUM(net_recv_bytes)"),
                    # Database: media E picco delle connessioni (il picco è ciò che satura
                    # max_connections), massimo del lag di replica nel blocco.
                    Arel.sql("AVG(db_connections)"), Arel.sql("MAX(db_connections)"),
                    Arel.sql("MAX(db_replication_lag_seconds)"),
                    Arel.sql("AVG(gpu_pct)"), Arel.sql("AVG(gpu_watt)"),
                    CPU_USER_AVG, CPU_SYSTEM_AVG, CPU_IOWAIT_AVG, CPU_STEAL_AVG)

      empty = { count: 0, cpu: nil, mem: nil, disk: nil, temp: nil, mem_gb: nil, disk_gb: nil,
                net_out: nil, net_in: nil, db_conn: nil, db_conn_max: nil, db_lag: nil,
                gpu: nil, gpu_watt: nil, cpu_user: nil, cpu_system: nil, cpu_iowait: nil, cpu_steal: nil }
      result = ids.index_with { Array.new(cfg[:count]) { |i| empty.merge(at: since + (i * cfg[:seconds])) } }
      rows.each do |hid, bucket_time, count, cpu, mem, disk, temp, mem_gb, disk_gb, net_out, net_in,
                    db_conn, db_conn_max, db_lag, gpu, gpu_watt, cpu_user, cpu_system, cpu_iowait,
                    cpu_steal|
        # round, non floor: `since` ha i nanosecondi e il bin torna dal DB al microsecondo, un soffio prima.
        idx = ((bucket_time.to_time - since) / cfg[:seconds]).round
        # Guardia difensiva irraggiungibile via test: idx è sempre in [0, count-1] perché la query
        # filtra recorded_at in [since, now) con date_bin d'origine `since` (come Metrics::Group).
        # simplecov:disable
        next unless idx.between?(0, cfg[:count] - 1)

        result[hid][idx] = {
          count: count, at: since + (idx * cfg[:seconds]),
          cpu: cpu&.to_f&.round(1), mem: mem&.to_f&.round(1), disk: disk&.to_f&.round(1),
          temp: temp&.to_f&.round(1), mem_gb: mem_gb&.to_f&.round(2), disk_gb: disk_gb&.to_f&.round(2),
          net_out: net_out&.to_i, net_in: net_in&.to_i,
          db_conn: db_conn&.to_f&.round(1), db_conn_max: db_conn_max&.to_i, db_lag: db_lag&.to_f&.round(3),
          gpu: gpu&.to_f&.round(1), gpu_watt: gpu_watt&.to_f&.round(1),
          cpu_user: cpu_user&.to_f&.round(1), cpu_system: cpu_system&.to_f&.round(1),
          cpu_iowait: cpu_iowait&.to_f&.round(1), cpu_steal: cpu_steal&.to_f&.round(1)
        }
        # simplecov:enable
      end
      result
    end

    # Dimensione di UN database nel tempo, per la sua pagina di dettaglio: stessi blocchi di
    # `buckets_for`, ma il valore non è una colonna — vive nello snapshot dentro `payload`.
    # Ritorna [{at:, size_bytes:}, …] vecchio→nuovo, `nil` dove non ci sono campioni.
    #
    # `jsonb_path_query_first` è SCALARE per riga: un `LATERAL jsonb_array_elements` moltiplicherebbe
    # 30 giorni di campioni per il numero di database dell'host. Il nome arriva come **variabile
    # jsonpath legata** (`vars`), mai interpolato nell'espressione: un database chiamato con apici o
    # con una sotto-espressione dentro resta un dato, non diventa codice.
    # NB: `$n` dentro la stringa jsonpath è una variabile JSONPATH (legata da `vars`), non un
    # placeholder SQL: i bind veri della query sono $1..$5.
    SIZE_BUCKETS_SQL = <<~SQL.squish
      SELECT date_bin($1::interval, recorded_at, $2::timestamptz) AS bucket,
             MAX((jsonb_path_query_first(payload,
                    '$.database.databases[*] ? (@.name == $n).size_bytes',
                    jsonb_build_object('n', $3::text))#>>'{}')::bigint) AS size_bytes
      FROM servers_samples
      WHERE host_id = $4::uuid AND recorded_at >= $2::timestamptz AND recorded_at < $5::timestamptz
      GROUP BY 1
    SQL

    def self.database_size_buckets(host_id:, name:, range:, now: Time.current)
      cfg = bucket_config(range)
      since = now - (cfg[:count] * cfg[:seconds])
      rows = connection.exec_query(SIZE_BUCKETS_SQL, "Servers::Sample database_size_buckets",
                                   [ cfg[:interval], since, name.to_s, host_id, now ])

      buckets = Array.new(cfg[:count]) { |i| { at: since + (i * cfg[:seconds]), size_bytes: nil } }
      rows.each do |row|
        # round, non floor: `since` ha i nanosecondi e il bin torna dal DB al microsecondo, un soffio prima.
        idx = ((row["bucket"].to_time - since) / cfg[:seconds]).round
        next unless idx.between?(0, cfg[:count] - 1)

        buckets[idx] = { at: since + (idx * cfg[:seconds]), size_bytes: row["size_bytes"]&.to_i }
      end
      buckets
    end

    # Variazione di dimensione di OGNI database nella finestra, per la colonna "Variazione" della lista
    # (Servers::DatabaseInventory): dal PRIMO all'ULTIMO campione osservato, per (host, nome). Ritorna
    # { [host_id, name] => delta_bytes }.
    #
    # In query, non in un campo pre-aggregato: la lista è rara e la finestra breve, così si evitano
    # migration, backfill e un valore da tenere in sync a ogni push. Batch e non per-database: due
    # DISTINCT ON prendono SOLO il campione più vecchio e il più nuovo per host (sull'indice
    # host_id+recorded_at, niente scansione dei giorni in mezzo), poi il delta si legge dal payload dei
    # due bordi — mai un jsonb_array_elements su TUTTI i campioni, come per database_size_buckets.
    #
    # Un database compare nell'hash SOLO se c'è al primo bordo E i due bordi sono istanti distinti: un
    # database più giovane della finestra (assente alla partenza) o un host con un solo campione non
    # ha una crescita da dichiarare e resta fuori → la lista mostra "—", non uno zero che si
    # leggerebbe come "non cresce" (il rischio esplicito di CYRA-474).
    def self.database_size_changes(host_ids:, range: "7d", now: Time.current)
      ids = Array(host_ids).uniq
      return {} if ids.blank?

      since = now - range_duration(range)
      window = where(host_id: ids, recorded_at: since...now)
      firsts = edge_payloads(window, :asc)
      lasts  = edge_payloads(window, :desc)

      ids.each_with_object({}) do |host_id, acc|
        first = firsts[host_id]
        last  = lasts[host_id]
        # Stesso istante = un solo campione: niente delta. (Bordi distinti → recorded_at diversi.)
        next if first.nil? || last.nil? || first[:at] == last[:at]

        first_sizes = first[:sizes]
        last[:sizes].each do |name, last_size|
          base = first_sizes[name]
          acc[[ host_id, name ]] = last_size - base unless base.nil?
        end
      end
    end

    # Il campione di bordo (più vecchio o più nuovo) per ogni host della finestra, con le dimensioni
    # dei suoi database già mappate name→size. DISTINCT ON (host_id) + ORDER BY host_id, recorded_at
    # prende una riga per host — è Postgres puro (come date_bin/jsonb qui sopra): l'app gira su
    # Postgres, i test pure.
    def self.edge_payloads(window, order)
      window.select("DISTINCT ON (host_id) host_id, recorded_at, payload")
            .order(:host_id, recorded_at: order)
            .each_with_object({}) do |sample, acc|
        acc[sample.host_id] = { at: sample.recorded_at, sizes: database_sizes_in(sample.payload) }
      end
    end

    # name→size_bytes dai database di UN payload di campione. Difensivo come il resto della pipeline:
    # payload monco, voce senza nome o array assente non fanno esplodere la lista, spariscono e basta.
    def self.database_sizes_in(payload)
      list = payload.is_a?(Hash) ? payload.dig("database", "databases") : nil
      return {} unless list.is_a?(Array)

      list.each_with_object({}) do |entry, acc|
        next unless entry.is_a?(Hash) && entry["name"].to_s.present?

        acc[entry["name"].to_s] = entry["size_bytes"].to_i
      end
    end
  end
end
