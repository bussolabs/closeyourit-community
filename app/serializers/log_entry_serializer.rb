# frozen_string_literal: true

# Espone i nomi semantici (logger/attributes) anche se le colonne sono logger_name/data (AR-safe).
class LogEntrySerializer < ApplicationSerializer
  attributes :id, :level, :message, :trace_id, :environment, :release, :occurred_at, :project_id

  attributes :event_id, :created_at, :signal_source, :severity_number, :severity_text, :span_id, :error_event_id, :otlp_payload

  attribute(:event_time_unix_nano) { |entry| entry.event_time_unix_nano&.to_i&.to_s }
  attribute(:observed_time_unix_nano) { |entry| entry.observed_time_unix_nano&.to_i&.to_s }

  attribute(:logger) { |entry| entry.logger_name }
  attribute(:attributes) { |entry| entry.data }
end
