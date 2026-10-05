# frozen_string_literal: true

require "date"

module SessionHealth
  module Ingest
    class Decode < ApplicationService
      Invalid = Class.new(ArgumentError)
      UINT64 = (2**64) - 1
      MAX_GROUPS = 1_000
      STATUSES = %w[ok exited crashed abnormal unhandled].freeze
      COUNTERS = %w[exited errored unhandled crashed abnormal].freeze
      TIMESTAMP = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})\z/
      UUID = /\A(?:[0-9a-f]{32}|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\z/i

      def initialize(type:, payload:)
        @type = type
        @payload = object(payload)
      end

      def call
        common = attributes
        return [ session(common) ] if @type == "session"
        raise Invalid, "Unsupported session item" unless @type == "sessions"

        groups = @payload["aggregates"]
        raise Invalid, "Invalid aggregate groups" unless groups.is_a?(Array) && groups.size <= MAX_GROUPS
        groups.map { |group| aggregate(object(group), common) }
      rescue ArgumentError, TypeError, RangeError
        raise Invalid, "Malformed session item"
      end

      private

      def session(common)
        status = @payload.fetch("status", "ok")
        raise Invalid unless STATUSES.include?(status)
        initial = @payload.fetch("init", false)
        raise Invalid unless [ true, false ].include?(initial)
        sid = @payload["sid"]
        raise Invalid unless (sid.nil? && status == "exited") || (sid.is_a?(String) && sid.match?(UUID) && sid.delete("-") != "0" * 32)
        started = timestamp(@payload["started"])
        updated = @payload.key?("timestamp") ? timestamp(@payload["timestamp"]) : Time.current
        started_ns = nanoseconds(started)
        updated_ns = nanoseconds(updated)
        sequence = initial ? 0 : integer(@payload.fetch("seq", updated_ns / 1_000_000))
        # Validate even an ignored init clock, so invalid wire types never disappear silently.
        integer(@payload["seq"]) if @payload.key?("seq")
        errors = integer(@payload.fetch("errors", 0))
        errors = [ errors, 1 ].max if status == "crashed"
        common.merge(sid: canonical_sid(sid), producer_identity: !sid.nil?, started_at: started,
          started_unix_nano: started_ns, update_unix_nano: updated_ns, sequence: sequence,
          status: status, errors: errors, duration: duration, initialization_seen: initial,
          timestamp_provided: @payload.key?("timestamp"), sequence_provided: @payload.key?("seq"),
          abnormal_mechanism: text(@payload["abnormal_mechanism"], limit: 256))
      end

      def canonical_sid(value)
        return nil if value.nil?
        value.delete("-").downcase.sub(/\A(.{8})(.{4})(.{4})(.{4})(.{12})\z/, '\\1-\\2-\\3-\\4-\\5')
      end

      def aggregate(group, common)
        started = timestamp(group["started"])
        raise Invalid unless started.sec.zero? && started.subsec.zero?
        common.merge(started_at: started).merge(COUNTERS.to_h { |key| [ key.to_sym, integer(group.fetch(key, 0)) ] })
      end

      def attributes
        attrs = object(@payload["attrs"])
        release = text(attrs["release"], limit: 1_024)
        raise Invalid if release.blank?
        { release: release, environment: text(attrs["environment"], limit: 256).presence }
      end

      def object(value)
        raise Invalid unless value.is_a?(Hash)
        value
      end

      def text(value, limit:)
        return nil if value.nil?
        raise Invalid unless value.is_a?(String) && value.valid_encoding? && value.bytesize <= limit && !value.include?("\u0000")
        Errors::Ingest::Scrub.call(payload: value)
      end

      def integer(value)
        raise Invalid unless value.is_a?(Integer) && value.between?(0, UINT64)
        value
      end

      def timestamp(value)
        raise Invalid unless value.is_a?(String) && value.match?(TIMESTAMP)
        DateTime.rfc3339(value)
        Time.iso8601(value).utc
      end

      def nanoseconds(value)
        integer((value.to_r * 1_000_000_000).to_i)
      end

      def duration
        value = @payload["duration"]
        return nil if value.nil?
        raise Invalid unless value.is_a?(Numeric) && value.finite? && value >= 0
        number = value.to_f
        raise Invalid unless number.finite?
        number
      end
    end
  end
end
