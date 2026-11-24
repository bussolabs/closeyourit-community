# frozen_string_literal: true

module Github
  class RecoverWebhooksJob < ApplicationJob
    queue_as :maintenance

    def perform
      WebhookDelivery.recoverable.order(:enqueued_at).limit(100).each(&:enqueue)
    end
  end
end
