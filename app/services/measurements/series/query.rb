# frozen_string_literal: true

module Measurements
  class Series
    class Query < ApplicationService
      class Invalid < StandardError; end
      KEYS = %w[id identity_digest name service_name service_namespace service_instance_id environment resource_attributes point_attributes].freeze

      def initialize(scope:, filters: {})
        @scope = scope
        raise Invalid, "Series filters exceed the byte limit" if filters.to_json.bytesize > 16.kilobytes
        @filters = filters.is_a?(String) ? JSON.parse(filters, max_nesting: 8) : filters
        raise Invalid, "Invalid series filters" unless @filters.is_a?(Hash) && (@filters.keys - KEYS).empty?
      rescue JSON::ParserError
        raise Invalid, "Invalid series filters"
      end

      def call
        count = @filters.except("resource_attributes", "point_attributes").size
        %w[resource_attributes point_attributes].each do |key|
          items = @filters.fetch(key, [])
          raise Invalid, "Invalid attribute predicates" unless items.is_a?(Array)
          count += items.size
          raise Invalid, "Too many series predicates" if count > 16
          items.each { |item| attribute(key == "resource_attributes" ? "resource" : "point_attributes", validate_attribute(item)) }
        end
        @filters.except("resource_attributes", "point_attributes").each { |key, value| scalar(key, value) }
        @scope.order(last_admitted_at: :desc, id: :desc)
      end

      private

      def scalar(key, value)
        raise Invalid, "Invalid series filter value" unless value.is_a?(String) && value.valid_encoding? && value.bytesize <= 256 && !value.include?("\0")
        case key
        when "id"
          raise Invalid, "Invalid series ID" unless value.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)
          @scope = @scope.where(id: value)
        when "identity_digest"
          raise Invalid, "Invalid identity digest" unless value.match?(/\A[0-9a-f]{64}\z/)
          @scope = @scope.where(identity_digest: value)
        when "name" then @scope = @scope.where(name: value)
        when "environment"
          canonical = { "attributes" => [ { "key" => "deployment.environment.name", "value" => { "stringValue" => value } } ] }.to_json
          legacy = { "attributes" => [ { "key" => "deployment.environment", "value" => { "stringValue" => value } } ] }.to_json
          exists = { "attributes" => [ { "key" => "deployment.environment.name" } ] }.to_json
          @scope = @scope.where("resource @> ?::jsonb OR (NOT resource @> ?::jsonb AND resource @> ?::jsonb)", canonical, exists, legacy)
        else
          name = { "service_name" => "service.name", "service_namespace" => "service.namespace", "service_instance_id" => "service.instance.id" }.fetch(key)
          attribute("resource", { "key" => name, "value" => { "stringValue" => value } })
        end
      end

      def validate_attribute(item)
        raise Invalid, "Invalid typed attribute predicate" unless item.is_a?(Hash) && item.keys.sort == %w[key value] && item["key"].is_a?(String) && item["key"].bytesize.between?(1, 256)
        value = item["value"]
        raise Invalid, "Invalid typed attribute predicate" unless value.is_a?(Hash) && value.size == 1
        raise Invalid, "Invalid typed attribute predicate" unless valid_scalar?(*value.first) && !item["key"].include?("\0")
        item
      end

      def valid_scalar?(type, data)
        case type
        when "stringValue" then data.is_a?(String) && data.valid_encoding? && data.bytesize <= 4096 && !data.include?("\0")
        when "intValue" then data.is_a?(String) && data.match?(/\A-?(?:0|[1-9]\d{0,18})\z/) && data.to_i.between?(-(2**63), (2**63) - 1)
        when "doubleValue" then data.is_a?(Numeric) && data.finite?
        when "boolValue" then data == true || data == false
        else false
        end
      end

      def attribute(column, item)
        value = column == "resource" ? { "attributes" => [ item ] } : [ item ]
        predicate = case column
        when "resource" then "resource @> ?::jsonb"
        when "point_attributes" then "point_attributes @> ?::jsonb"
        else raise Invalid, "Invalid attribute column"
        end
        @scope = @scope.where(predicate, value.to_json)
      end
    end
  end
end
