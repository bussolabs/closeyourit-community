# frozen_string_literal: true

module Uptime
  # Costanti del dominio uptime (rules/constants.md).
  module Constants
    # Retention per granularità (righe `uptime_checks` discriminatore `granularity`).
    # I ping raw coprono le finestre brevi (30m/24h) live; oltre, si leggono i rollup hourly (7d/30d) e
    # daily (1y, 365 slot). Raw ≥ 24h + slack per il rollup orario. PruneJob pota ogni granularità.
    # Raw/hourly restano costanti fisse (buffer interni dei rollup); solo il daily è configurabile
    # (CYRA-159, gerarchia god → org → progetto) — è la storia a lungo termine visibile all'utente.
    RAW_RETENTION_DAYS = 3
    HOURLY_RETENTION_DAYS = 90
    RETENTION_DEFAULT_DAYS = 730
  end
end
