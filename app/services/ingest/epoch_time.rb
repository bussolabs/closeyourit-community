# frozen_string_literal: true

module Ingest
  # Parsing dell'occurred_at per i domini a basso rumore temporale (Logs/Analytics::Ingest::Normalize,
  # byte-identici prima di questa estrazione): epoch in secondi o millisecondi (JS `Date.now()`),
  # clampato se nel futuro oltre la tolleranza di clock-skew.
  #
  # Le due MISURE (soglia e tolleranza) sono la ragione d'essere di questo modulo: la regola sta in
  # Ingest::Normalization e qui si dichiara solo con che numeri applicarla. Errors la applica con
  # numeri suoi, deliberatamente diversi (soglia ms 1e12 vs 1e11 qui, skew 5 minuti vs 1 ora qui).
  module EpochTime
    # Epoch ≥ questa soglia è quasi certamente in millisecondi (errore JS `Date.now()`): l'anno ~5138
    # in secondi. Sotto, sono secondi.
    MS_EPOCH_THRESHOLD = 100_000_000_000
    # Tolleranza per clock-skew del client: oltre, l'occurred_at è considerato corrotto → now.
    MAX_FUTURE_SKEW = 1.hour

    # Earliest created_at a row with occurred_at >= `from` can have. Monthly partitions are keyed on
    # created_at, so range queries add it to skip the old months (CYRA-891).
    def self.insert_floor(from) = from - MAX_FUTURE_SKEW

    def parse_time(timestamp)
      parsed = case timestamp
      when Numeric then Normalization.epoch_to_time(timestamp, ms_threshold: MS_EPOCH_THRESHOLD)
      when String  then (Time.zone.parse(timestamp) rescue nil)
      end || Time.current
      clamp_future(parsed)
    end

    # Epoch in ms (≥ soglia) → secondi: evita timestamp nell'anno 55840 da `Date.now()` lato client.
    def normalize_epoch(value)
      Normalization.epoch_seconds(value, ms_threshold: MS_EPOCH_THRESHOLD)
    end

    # Un occurred_at oltre la tolleranza di skew è corrotto → now (così non resta in cima allo stream).
    def clamp_future(time)
      Normalization.clamp_future(time, skew: MAX_FUTURE_SKEW)
    end
  end
end
