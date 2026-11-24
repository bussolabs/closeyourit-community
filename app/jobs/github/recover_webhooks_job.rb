# frozen_string_literal: true

module Github
  class RecoverWebhooksJob < ApplicationJob
    queue_as :maintenance
    limits_concurrency to: 1, key: "periodic", duration: 5.minutes, on_conflict: :discard

    def perform
      WebhookDelivery.recoverable.order(:enqueued_at).limit(100).each(&:enqueue)
    end
  end
end
