# frozen_string_literal: true

module Seo
  # Potatura notturna. Due tagli e una cosa che non si taglia mai.
  #
  # - Le PAGINE che non si vedono da mesi: sono state cancellate o rinominate, e tenerle vuol dire
  #   mostrare un elenco che non somiglia più al sito.
  # - Gli AUDIT e le MISURE DI VELOCITÀ vecchi: servono al trend recente, non all'archeologia.
  # - I RILIEVI non si potano MAI: sono la memoria di quanto è rimasto aperto un problema, e di
  #   cosa qualcuno aveva deciso di ignorare. Stessa scelta dei finding delle vulnerabilità.
  class PruneJob < ApplicationJob
    queue_as :batch

    PAGE_RETENTION = 90.days
    AUDIT_RETENTION = 180.days
    # Stessa finestra degli audit: una misura di velocità serve a rispondere «è peggiorato dopo il
    # rilascio di giovedì», non a ricostruire com'era il sito due anni fa. Due righe al giorno per
    # sito: il volume non è il motivo, la leggibilità del grafico sì.
    LAB_RUN_RETENTION = 180.days

    def perform(now = Time.current)
      Seo::Page.where(last_seen_at: ..(now - PAGE_RETENTION)).in_batches(&:delete_all)
      Seo::Audit.where(started_at: ..(now - AUDIT_RETENTION)).in_batches(&:delete_all)
      Seo::LabRun.where(started_at: ..(now - LAB_RUN_RETENTION)).in_batches(&:delete_all)
    end
  end
end
