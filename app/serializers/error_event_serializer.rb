# frozen_string_literal: true

class ErrorEventSerializer < ApplicationSerializer
  attributes :id, :event_id, :level, :environment, :release, :occurred_at,
             :handled, :trace_id, :span_id, :stacktrace, :context, :payload
  attribute :symbolication do |event|
    (params[:symbolications] || {})[[ event.project_id, event.id, event.created_at ]] || { version: 1, status: "pending", frames: [] }
  end
end
