# frozen_string_literal: true

module Analytics
  # Pota i pageview oltre la retention risolta PER-PROGETTO (god → org → progetto, come i log) e
  # distrugge i salt giornalieri oltre ANALYTICS_SALT_RETENTION_DAYS — è la distruzione del salt a
  # rendere gli hash storici irreversibili (postura GDPR). Daily (recurring.yml).
  class PruneJob < ApplicationJob
    queue_as :batch

    def perform
      global_days = Analytics::Retention.resolve(Settings::Global.instance.analytics_retention_days)

      # CYRA-750 — prima le FETTE. La tabella è divisa a fette mensili sull'istante d'arrivo: una
      # fetta interamente fuori dalla finestra PIÙ LUNGA in vigore si stacca in un istante, con lo
      # spazio che torna subito al filesystem. Quello che resta — il residuo del mese a cavallo e i
      # clienti che conservano meno — continua a essere potato riga per riga qui sotto, ciascuno con
      # la propria finestra.
      Ops::Partitions::DropExpired.call(table: "analytics_pageviews",
                                        keep_from: Monitoring::Retention.longest(key: :analytics, global_days: global_days).days.ago)

      Projects::Project.includes(:organization).find_each do |project|
        days = Analytics::Retention.for(project, global_days: global_days)
        threshold = days.days.ago
        project.analytics_pageviews.where(created_at: ..threshold).in_batches.delete_all
        # Le misure di velocità (CYRA-538) nascono dallo stesso visitatore e si potano con la stessa
        # finestra: due durate diverse per lo stesso dato sono un modo per ritrovarsi in casa
        # qualcosa che non si doveva più avere.
        Analytics::WebVital.where(project_id: project.id, created_at: ..threshold).in_batches.delete_all
      end

      salt_cutoff = Time.current.utc.to_date - Analytics::Constants::SALT_RETENTION_DAYS
      Analytics::Salt.where(date: ...salt_cutoff).delete_all
    end
  end
end
