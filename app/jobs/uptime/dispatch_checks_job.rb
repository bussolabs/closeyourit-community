# frozen_string_literal: true

module Uptime
  # Dispatcher ricorrente (ogni minuto): accoda un CheckJob per ogni monitor scaduto. Il fan-out tiene
  # corto il job ricorrente e isola il ping di ogni monitor.
  class DispatchChecksJob < ApplicationJob
    queue_as :uptime
    limits_concurrency to: 1, key: "periodic", duration: 5.minutes, on_conflict: :discard

    def perform
      Uptime::Monitor.due.find_each { |monitor| Uptime::CheckJob.perform_later(monitor.id) }
    end
  end
end
