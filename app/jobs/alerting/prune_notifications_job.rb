# frozen_string_literal: true

module Alerting
  # Retention del notification center: elimina le notifiche oltre 30 giorni (ricorrente, coda :batch).
  class PruneNotificationsJob < ApplicationJob
    queue_as :batch

    RETENTION = 30.days

    def perform
      expired = Alerting::Notification.where(created_at: ..RETENTION.ago)
      loop do
        # A primary-key cursor can scan recent rows on every batch. CYRA-1268.
        ids = expired.reorder(:created_at).limit(1_000).pluck(:id)
        break if ids.empty?

        expired.where(id: ids).delete_all
      end
    end
  end
end
