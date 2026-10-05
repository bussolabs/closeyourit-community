# frozen_string_literal: true

class MeasurementPointSerializer < ApplicationSerializer
  attributes :series_id, :payload, :first_received_at
  attribute(:api_schema_version) { 1 }
  attribute(:start_time_unix_nano) { |point| point.start_time_unix_nano.to_i.to_s }
  attribute(:time_unix_nano) { |point| point.time_unix_nano.to_i.to_s }
end
