# frozen_string_literal: true

module Uptime
  # Riga di `uptime_checks` multi-granularità (discriminatore `granularity`):
  # - `check`  = esito immutabile di un ping (up/status_code/response_time_ms/error). È il default (0).
  # - `hourly`/`daily` = bucket AGGREGATO scritto da Uptime::RollupJob via upsert: contatori
  #   (checks_total/checks_up/avg_response_ms) + denorm incident sul daily (incidents_count/downtime_seconds).
  #   `checked_at` sugli aggregati = inizio del bucket (UTC); `up`/`status_code`/`error` restano nil.
  class Check < ApplicationRecord
    self.table_name = "uptime_checks"

    belongs_to :monitor, class_name: "Uptime::Monitor", inverse_of: :checks

    enum :granularity, { check: 0, hourly: 1, daily: 2 }, prefix: :granularity

    # `up` ha senso solo sul ping raw: gli aggregati non hanno un esito singolo (up=nil ammesso).
    validates :up, inclusion: { in: [ true, false ] }, if: :granularity_check?
    validates :checked_at, presence: true

    # `raw` = solo i ping (esclude i bucket aggregati). Protegge le letture/associazioni esistenti,
    # che devono continuare a vedere SOLO i ping dopo l'introduzione degli aggregati nella stessa tabella.
    scope :raw, -> { granularity_check }
    scope :aggregated, -> { where.not(granularity: :check) }
    scope :recent, -> { order(checked_at: :desc) }
  end
end
