# frozen_string_literal: true

module Chat
  # Fan-out delle notifiche per un nuovo messaggio di chat. Enqueued da Chat::PostMessage dopo il
  # commit (esplicito, non after_commit — coerente con Ticketing). Idempotente (dedup_key): un retry
  # non duplica. Messaggio sparito → no-op.
  class NotifyJob < ApplicationJob
    queue_as :notifications

    def perform(message_id:)
      message = Chat::Message.find_by(id: message_id)
      return if message.nil?

      Chat::Notifications::Dispatch.call(message: message)
    end
  end
end
