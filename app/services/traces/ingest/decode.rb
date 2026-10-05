# frozen_string_literal: true

module Traces
  module Ingest
    # Validate the wire shape before database admission, without logging untrusted values.
    class Decode < ApplicationService
      include ::Ingest::OtlpValues
      MAX_SPANS = 1_000
      Result = Data.define(:spans, :rejected)

      def initialize(payload:)
        @payload = payload
      end

      def call
        records = []
        rejected = 0
        count = 0
        array(object(@payload)["resourceSpans"]).each do |resource|
          object(resource)
          array(resource["scopeSpans"]).each do |scope|
            object(scope)
            array(scope["spans"]).each do |span|
              count += 1
              raise Malformed, "Too many spans" if count > MAX_SPANS
              begin
                records << decode_span(span, resource, scope)
              rescue Rejected
                rejected += 1
              end
            end
          end
        end
        Result.new(spans: records, rejected: rejected)
      end

      private

      def decode_span(value, resource_group, scope_group)
        value = object(value)
        start_ns = integer(value["startTimeUnixNano"], min: 1)
        end_ns = integer(value["endTimeUnixNano"], min: start_ns)
        span_id = identifier(value["spanId"], length: 16)
        parent = identifier(value["parentSpanId"], length: 16, empty: true)
        raise Rejected, "Span cannot parent itself" if parent == span_id
        status = object(value["status"] || {})
        payload = {
          "traceId" => identifier(value["traceId"], length: 32), "spanId" => span_id,
          "parentSpanId" => parent || "", "traceState" => text(value["traceState"]),
          "flags" => integer(value.fetch("flags", 0), max: (2**32) - 1),
          "name" => text(value["name"]), "kind" => integer(value.fetch("kind", 0), max: 5),
          "startTimeUnixNano" => start_ns.to_s, "endTimeUnixNano" => end_ns.to_s,
          "attributes" => attributes(value["attributes"]),
          "status" => { "code" => integer(status.fetch("code", 0), max: 2), "message" => text(status["message"]) },
          "events" => array(value["events"]).map { |event| decode_event(event) },
          "links" => array(value["links"]).map { |link| decode_link(link) }
        }
        %w[droppedAttributesCount droppedEventsCount droppedLinksCount].each do |key|
          payload[key] = integer(value.fetch(key, 0), max: (2**32) - 1)
        end
        { payload: payload, resource: resource(resource_group["resource"]),
          instrumentation_scope: scope(scope_group["scope"]),
          resource_schema_url: text(resource_group["schemaUrl"]), scope_schema_url: text(scope_group["schemaUrl"]) }
      end

      def decode_event(value)
        object(value)
        { "timeUnixNano" => integer(value.fetch("timeUnixNano", 0)).to_s,
          "name" => text(value["name"]), "attributes" => attributes(value["attributes"]),
          "droppedAttributesCount" => integer(value.fetch("droppedAttributesCount", 0), max: (2**32) - 1) }
      end

      def decode_link(value)
        object(value)
        attrs = attributes(value["attributes"])
        state = text(value["traceState"])
        ids = %w[traceId spanId].zip([ 32, 16 ]).to_h do |key, length|
          id = value[key]
          empty = id.nil? || id == "" || id == "0" * length
          raise Rejected, "Empty link" if empty && attrs.empty? && state.empty?
          [ key, empty ? "" : identifier(id, length: length) ]
        end
        ids.merge("traceState" => state, "attributes" => attrs,
          "flags" => integer(value.fetch("flags", 0), max: (2**32) - 1),
          "droppedAttributesCount" => integer(value.fetch("droppedAttributesCount", 0), max: (2**32) - 1))
      end
    end
  end
end
