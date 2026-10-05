# frozen_string_literal: true

module Analytics
  # Decadimento del chip "visitatori online" della dashboard analytics. Il realtime cable
  # (Analytics::Broadcast su nuovo pageview) tiene live gli aggregati quando ARRIVA traffico, ma non fa
  # scendere il conteggio quando i visitatori ESCONO dalla finestra (nessun pageview = nessun evento che
  # triggeri un refresh). Questo job, ogni minuto, ri-broadcasta i progetti con attività recente (ultimo
  # pageview entro ANALYTICS_REALTIME_WINDOW + 1 minuto di margine): ogni viewer ri-fetcha la propria show
  # e il chip si ricalcola, scendendo man mano che la finestra di 5 min si svuota. Oltre quella finestra
  # il progetto non è più "attivo" → niente broadcast, e l'ultimo refresh ha già portato il chip verso 0.
  # Il throttle di Broadcast.refresh (2s) non interferisce (il job gira ogni 60s). Pattern gemello di
  # Servers::CheckStaleJob (job ricorrente every-minute che broadcasta).
  class DecayRealtimeJob < ApplicationJob
    queue_as :maintenance

    def perform
      cutoff = (Analytics::Constants::REALTIME_WINDOW + 1.minute).ago
      project_ids = Analytics::Pageview.where(occurred_at: cutoff.., created_at: ::Ingest::EpochTime.insert_floor(cutoff)..)
                                       .distinct.pluck(:project_id)
      return if project_ids.empty?

      Projects::Project.where(id: project_ids).find_each do |project|
        Analytics::Broadcast.refresh(project)
      end
    end
  end
end
