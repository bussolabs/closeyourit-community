# frozen_string_literal: true

module Ticketing
  # Fan-out delle notifiche per un evento ticket (creato/assegnato/stato/milestone). Enqueued
  # dall'after_commit di Ticketing::Event → gira DOPO il commit della mutazione. Idempotente
  # (dedup_key sulle notifiche): un retry non duplica. Evento sparito → no-op (discard implicito).
  class NotifyJob < ApplicationJob
    queue_as :notifications

    def perform(event_id:)
      event = Ticketing::Event.find_by(id: event_id)
      return if event.nil?

      Ticketing::Notifications::DispatchEvent.call(event: event)
    end
  end
end
