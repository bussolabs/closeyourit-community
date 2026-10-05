# frozen_string_literal: true

module Crashes
  # A late authoritative event must never inherit an attachment for another release/build.
  class Reconcile < ApplicationService
    def initialize(project:, event:)
      @project, @event = project, event
    end

    def call
      return unless @event && @project.crash_reports.where(event_id: @event.event_id).exists?
      @project.with_lock do
        report = @project.crash_reports.find_by(event_id: @event.event_id)
        next unless report
        if %w[release environment dist].any? { |key| report.public_send(key).presence != Identity.metadata(@event)[key].presence } || !Identity.compatible_build?(@event.payload, report.manifest)
          report.destroy!
          ActiveSupport::Notifications.instrument("crashes.rejected", reason: "event_metadata_conflict", count: 1)
        end
      end
    end
  end
end
