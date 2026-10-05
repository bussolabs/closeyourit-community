# frozen_string_literal: true

class TraceSpanSerializer < ApplicationSerializer
  attributes :trace_id, :span_id, :parent_span_id, :name, :kind, :status_code, :service_name,
             :resource, :instrumentation_scope, :resource_schema_url, :scope_schema_url, :payload, :first_received_at
  attribute(:api_schema_version) { 1 }
  attribute(:resource_identity) { |span| span.resource_identity }
  attribute(:start_time_unix_nano) { |span| span.start_time_unix_nano.to_i.to_s }
  attribute(:end_time_unix_nano) { |span| span.end_time_unix_nano.to_i.to_s }
end
