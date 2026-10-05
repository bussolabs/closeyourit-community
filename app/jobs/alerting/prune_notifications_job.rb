# frozen_string_literal: true

module Alerting
  # Retention del notification center: elimina le notifiche oltre 30 giorni (ricorrente, coda :batch).
  class PruneNotificationsJob < ApplicationJob
    queue_as :batch

    RETENTION = 30.days

    def perform
      Alerting::Notification.where(created_at: ..RETENTION.ago).in_batches.delete_all
    end
  end
end
