# frozen_string_literal: true

module Usage
  # CYSK-29 — due upsert_all per flush, mai per simbolo. Multi-processo: ognuno flusha la propria
  # vista e qui si fonde con GREATEST(last_seen_at) — l'ordine di arrivo non conta. `hits_count` si
  # somma ma resta indicativo: la sola colonna portante è `last_seen_at`.
  #
  # CYRA-1232 — le voci ripetute dello stesso flush (stesso kind e simbolo) si FONDONO prima
  # dell'upsert: Postgres rifiuta un ON CONFLICT che tocca due volte la stessa riga, l'errore non è
  # tra i guasti ritentati e il flush intero andava perso. I due upsert stanno in UNA transazione:
  # se il secondo cade, il primo si annulla e il ritentativo riparte da zero invece di sommare due
  # volte gli stessi hit.
  class IngestJob < ApplicationJob
    queue_as :default

    def perform(project_id:, environment:, sdk:, release:, truncated:, symbols:)
      now = Time.current
      rows = symbols.filter_map do |item|
        kind = item["kind"].to_s
        symbol = item["symbol"].to_s
        next unless ::Usage::Symbol::KINDS.include?(kind) && symbol.match?(::Usage::Symbol::SYMBOL_FORMAT)

        seen = parse_time(item["last_seen_at"]) || now
        { project_id: project_id, environment: environment, kind: kind, symbol: symbol,
          first_seen_at: seen, last_seen_at: seen, hits_count: item["count"].to_i,
          last_release: release, last_sdk_version: sdk["version"].presence,
          created_at: now, updated_at: now }
      end
      rows = merge_repeated(rows)

      # Un reporter per kind visto nel flush: registra che il canale è VIVO. Un flush senza simboli
      # validi non scrive niente — nessun kind, nessuna riga. `truncated` squalifica il kind
      # presso lo scanner.
      reporter_rows = rows.map { |row| row[:kind] }.uniq.map do |kind|
        { project_id: project_id, environment: environment, kind: kind,
          sdk_name: sdk["name"].to_s, sdk_version: sdk["version"].presence, release: release,
          first_reported_at: now, last_reported_at: now, truncated_last_window: truncated,
          created_at: now, updated_at: now }
      end
      return if reporter_rows.empty?

      ::Usage::Symbol.transaction do
        ::Usage::Symbol.upsert_all(
          rows,
          unique_by: "idx_usage_symbols_identity",
          on_duplicate: Arel.sql(<<~SQL.squish)
            last_seen_at = GREATEST(usage_symbols.last_seen_at, EXCLUDED.last_seen_at),
            hits_count = usage_symbols.hits_count + EXCLUDED.hits_count,
            last_release = COALESCE(EXCLUDED.last_release, usage_symbols.last_release),
            last_sdk_version = COALESCE(EXCLUDED.last_sdk_version, usage_symbols.last_sdk_version),
            updated_at = EXCLUDED.updated_at
          SQL
        )

        ::Usage::Reporter.upsert_all(
          reporter_rows,
          unique_by: "idx_usage_reporters_identity",
          on_duplicate: Arel.sql(<<~SQL.squish)
            last_reported_at = GREATEST(usage_reporters.last_reported_at, EXCLUDED.last_reported_at),
            sdk_version = COALESCE(EXCLUDED.sdk_version, usage_reporters.sdk_version),
            release = COALESCE(EXCLUDED.release, usage_reporters.release),
            truncated_last_window = EXCLUDED.truncated_last_window,
            updated_at = EXCLUDED.updated_at
          SQL
        )
      end
    end

    private

    # Una riga per (kind, simbolo): gli hit si sommano e il tetto si applica DOPO la somma, la finestra
    # va dal primo all'ultimo visto, release e versione SDK restano le ultime non nulle.
    def merge_repeated(rows)
      rows.group_by { |row| row.values_at(:kind, :symbol) }.map do |_identity, group|
        group.last.merge(
          first_seen_at: group.map { |row| row[:first_seen_at] }.min,
          last_seen_at: group.map { |row| row[:last_seen_at] }.max,
          hits_count: group.sum { |row| row[:hits_count] }.clamp(0, 2**40),
          last_release: group.filter_map { |row| row[:last_release] }.last,
          last_sdk_version: group.filter_map { |row| row[:last_sdk_version] }.last
        )
      end
    end

    def parse_time(raw)
      Time.iso8601(raw.to_s)
    rescue ArgumentError
      nil
    end
  end
end
