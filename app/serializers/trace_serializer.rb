# frozen_string_literal: true

class TraceSerializer < ApplicationSerializer
  attributes :trace_id, :first_received_at, :last_received_at, :retained_spans_count, :expired_spans_count
  attribute(:api_schema_version) { 1 }
  attribute(:topology) { |trace| trace.topology }
end
