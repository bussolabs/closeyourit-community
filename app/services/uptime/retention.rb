# frozen_string_literal: true

module Uptime
  # Giorni di conservazione della storia daily di un progetto — SOLO il daily, che è la storia a
  # lungo termine visibile all'utente: raw e hourly restano costanti fisse, buffer interni dei
  # rollup (Uptime::Constants::{RAW,HOURLY}_RETENTION_DAYS). La regola (nearest-wins progetto →
  # org → god globale → default di sistema) vive tutta in Monitoring::Retention.
  module Retention
    module_function

    def for(project, global_days: :unset)
      Monitoring::Retention.for(project, key: :uptime, global_days: global_days)
    end

    # Intero positivo o nil (un valore assente/zero/blank → eredita).
    def resolve(value) = Monitoring::Retention.resolve(value)
  end
end
