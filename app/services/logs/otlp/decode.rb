# frozen_string_literal: true

module Logs
  module Otlp
    class Decode < ApplicationService
      include ::Ingest::OtlpValues
      Result = Data.define(:records, :rejected)
      MAX_RECORDS = 1_000

      def initialize(payload:)
        @payload = payload
      end

      def call
        records = []
        rejected = 0
        count = 0
        array(object(@payload)["resourceLogs"]).each do |resource_group|
          object(resource_group)
          array(resource_group["scopeLogs"]).each do |scope_group|
            object(scope_group)
            array(scope_group["logRecords"]).each do |log|
              count += 1
              raise Malformed, "Too many log records" if count > MAX_RECORDS
              begin
                records << decode_log(log, resource_group, scope_group)
              rescue Rejected
                rejected += 1
              end
            end
          end
        end
        Result.new(records: records, rejected: rejected)
      end

      private

      def decode_log(log, resource_group, scope_group)
        object(log)
        attrs = attributes(log["attributes"])
        values = attrs.to_h { |item| [ item["key"], item.fetch("value")["stringValue"] ] }
        producer_uid = identity(log, "log.record.uid")
        error_id = identity(log, "closeyourit.error.event_id", error: true)
        record = {
          "timeUnixNano" => integer(log.fetch("timeUnixNano", 0)).to_s,
          "observedTimeUnixNano" => integer(log.fetch("observedTimeUnixNano", 0)).to_s,
          "severityNumber" => integer(log.fetch("severityNumber", 0), max: 24),
          "severityText" => text(log["severityText"]), "eventName" => text(log["eventName"]),
          "traceId" => identifier(log["traceId"], length: 32, empty: true) || "",
          "spanId" => identifier(log["spanId"], length: 16, empty: true) || "",
          "flags" => integer(log.fetch("flags", 0), max: (2**32) - 1),
          "droppedAttributesCount" => integer(log.fetch("droppedAttributesCount", 0), max: (2**32) - 1),
          "attributes" => attrs, "body" => any_value(log["body"], depth: 0)
        }
        { record: record, resource: resource(resource_group["resource"]), instrumentation_scope: scope(scope_group["scope"]),
          resource_schema_url: text(resource_group["schemaUrl"]), scope_schema_url: text(scope_group["schemaUrl"]),
          producer_uid: producer_uid, error_event_id: error_id,
          exception: record["eventName"] == "exception" && values["exception.type"].present? }
      end

      def identity(log, key, error: false)
        entry = array(log["attributes"]).find { |item| item["key"] == key }
        return nil unless entry
        value = object(entry["value"])["stringValue"]
        pattern = error ? /\A[0-9a-f]{32}\z/i : /\A[A-Za-z0-9][A-Za-z0-9_.:\/-]{0,255}\z/
        raise Rejected, "Invalid explicit event identity" unless value.is_a?(String) && value.match?(pattern) && text(value) == value
        error ? value.downcase : value
      end
    end
  end
end
