# frozen_string_literal: true

class MetricSampleSerializer < ApplicationSerializer
  attributes :id, :sample_id, :kind, :subtype, :duration_ms, :environment, :occurred_at, :trace_id, :payload
end
