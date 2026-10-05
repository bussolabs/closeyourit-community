# frozen_string_literal: true

module Logs
  # Pota i log oltre la retention risolta PER-PROGETTO (god → org → progetto). Daily (recurring.yml).
  # A differenza di errori/metriche (30g hardcoded), la retention dei log è configurabile a 3 livelli.
  class PruneJob < ApplicationJob
    queue_as :batch

    def perform
      # Singleton god risolto UNA volta (non per-progetto) + organization in eager load → niente N+1.
      # La gerarchia vive in Logs::Retention.for (fonte unica): qui si passa solo il global pre-risolto.
      global_days = Logs::Retention.resolve(Settings::Global.instance.logs_retention_days)

      # CYRA-750 — prima le FETTE. La tabella è divisa a fette mensili sull'istante d'arrivo: una
      # fetta interamente fuori dalla finestra PIÙ LUNGA in vigore si stacca in un istante, con lo
      # spazio che torna subito al filesystem. Quello che resta — il residuo del mese a cavallo e i
      # clienti che conservano meno — continua a essere potato riga per riga qui sotto, ciascuno con
      # la propria finestra.
      Ops::Partitions::DropExpired.call(table: "logs_entries",
                                        keep_from: Monitoring::Retention.longest(key: :logs, global_days: global_days).days.ago)

      Projects::Project.includes(:organization).find_each do |project|
        days = Logs::Retention.for(project, global_days: global_days)
        project.logs_entries.where(created_at: ..days.days.ago).in_batches.delete_all
      end

      prune_orphan_links
    end

    private

    # CYRA-750 — i collegamenti manuali (log ↔ errore/ticket) non sono più tenuti dal database: una
    # chiave esterna verso una tabella a fette pretenderebbe che la colonna riferita sia unica, e su
    # una tabella divisa l'unicità deve contenere il tempo. Senza questa passata un log potato — a
    # riga o con la sua fetta — lascerebbe dietro un collegamento che punta al nulla, e la pagina
    # dell'errore mostrerebbe un log che non c'è più. Anti-join e non `NOT IN`: la lista dei log vivi
    # è enorme, la tabella dei collegamenti no.
    def prune_orphan_links
      Logs::Link.connection.execute(<<~SQL.squish)
        DELETE FROM logs_links l
        WHERE NOT EXISTS (SELECT 1 FROM logs_entries e WHERE e.id = l.log_entry_id)
      SQL
    end
  end
end
