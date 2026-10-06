# frozen_string_literal: true

module Crashes
  module Cocoa
    class Record < ApplicationService
      def initialize(project:, event:)
        @project, @event = project, event
      end

      def call
        return unless @event && @event.project_id == @project.id && @event.payload["platform"] == "cocoa"
        return if @event.created_at < Errors::Retention.for(@project).days.ago
        manifest = Manifest.call(payload: @event.payload)
        @project.with_lock do
          report = @project.crash_reports.find_by(event_id: @event.event_id)
          return report if report&.manifest.present?
          report ||= @project.crash_reports.build(event_id: @event.event_id)
          report.assign_attributes(Identity.metadata(@event).merge("manifest" => manifest))
          report.save!
          report
        end
      rescue Rejected => error
        ActiveSupport::Notifications.instrument("crashes.rejected", reason: error.message, count: 1)
        nil
      end
    end
  end
end
