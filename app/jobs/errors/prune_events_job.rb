# frozen_string_literal: true

module Errors
  # Pota gli eventi (Errors::Event) oltre la retention risolta PER-PROGETTO (god → org → progetto,
  # come i log — CYRA-159). I contatori sul gruppo (events_count/users_count) RESTANO — la storia
  # aggregata sopravvive alla potatura. Daily (recurring.yml).
  class PruneEventsJob < ApplicationJob
    queue_as :batch

    def perform
      # Singleton god risolto UNA volta (non per-progetto) + organization in eager load → niente N+1.
      global_days = Errors::Retention.resolve(Settings::Global.instance.errors_retention_days)

      # CYRA-750 — prima le FETTE. La tabella è divisa a fette mensili sull'istante d'arrivo: una
      # fetta interamente fuori dalla finestra PIÙ LUNGA in vigore si stacca in un istante, con lo
      # spazio che torna subito al filesystem. Quello che resta — il residuo del mese a cavallo e i
      # clienti che conservano meno — continua a essere potato riga per riga qui sotto, ciascuno con
      # la propria finestra.
      Ops::Partitions::DropExpired.call(table: "errors_events",
                                        keep_from: Monitoring::Retention.longest(key: :errors, global_days: global_days).days.ago)

      Projects::Project.includes(:organization).find_each do |project|
        days = Errors::Retention.for(project, global_days: global_days)
        project.error_events.where(created_at: ..days.days.ago).in_batches.delete_all
      end
    end
  end
end
