# frozen_string_literal: true

require "digest"

module Measurements
  module Ingest
    class Record < ApplicationService
      ACTIVE_SERIES_LIMIT = 10_000
      Result = Data.define(:rejected)

      def initialize(project:, payload:)
        @project = project
        @payload = payload
      end

      def call
        decoded = Decode.call(payload: @payload)
        return Result.new(rejected: decoded.rejected) if decoded.points.empty?
        rejected = @project.with_lock { persist(decoded.points) }
        Result.new(rejected: rejected + decoded.rejected)
      end

      private

      def persist(points)
        now = Time.current
        cutoff = now - 24.hours
        grouped = points.group_by { |point| series_identity(point.fetch(:series)) }
        series = @project.measurement_series.where(identity_digest: grouped.keys)
          .select(:id, :identity_digest, :last_admitted_at).index_by(&:identity_digest)
        known = existing_points(grouped, series)
        active = @project.measurement_series.where(last_admitted_at: cutoff..).count
        admitted = {}
        rejected = 0
        grouped.each do |key, group|
          fresh, conflicts = new_points(group, known.fetch(series[key]&.id, {}))
          rejected += conflicts
          next if fresh.empty?
          needs_slot = series[key].nil? || series[key].last_admitted_at < cutoff
          if needs_slot && active >= ACTIVE_SERIES_LIMIT
            rejected += fresh.sum { |point| point.fetch(:occurrences) }
          else
            active += 1 if needs_slot
            admitted[key] = fresh
          end
        end
        persist_admitted(admitted, series, now)
        rejected
      end

      def existing_points(groups, series)
        relation = @project.measurement_points.none
        groups.each do |key, points|
          next unless series[key]
          points.each do |point|
            payload = point.fetch(:payload)
            relation = relation.or(@project.measurement_points.where(series_id: series[key].id,
              start_time_unix_nano: payload.fetch("startTimeUnixNano"), time_unix_nano: payload.fetch("timeUnixNano")))
          end
        end
        relation.pluck(:series_id, :start_time_unix_nano, :time_unix_nano, :payload_digest)
          .each_with_object({}) do |(series_id, start_ns, end_ns, digest), result|
            (result[series_id] ||= {})[[ start_ns.to_i.to_s, end_ns.to_i.to_s ]] = digest
          end
      end

      def persist_admitted(admitted, existing, now)
        return if admitted.empty?
        new_series = admitted.reject { |key, _| existing.key?(key) }.map do |key, points|
          points.first.fetch(:series).merge(project_id: @project.id, identity_digest: key,
            first_received_at: now, last_admitted_at: now)
        end
        Measurements::Series.insert_all!(new_series) if new_series.any?
        ids = @project.measurement_series.where(identity_digest: admitted.keys).pluck(:identity_digest, :id).to_h
        rows = admitted.flat_map do |key, points|
          points.map { |point| point_attributes(point, ids.fetch(key), now) }
        end
        Measurements::Point.insert_all!(rows)
        @project.measurement_series.where(id: ids.values).update_all(last_admitted_at: now, updated_at: now)
      end

      def new_points(points, known)
        fresh = {}
        conflicts = 0
        points.each do |point|
          payload = point.fetch(:payload)
          key = payload.values_at("startTimeUnixNano", "timeUnixNano")
          fingerprint = digest(payload)
          if known.key?(key)
            if known[key] != fingerprint
              conflicts += 1
            elsif fresh.key?(key)
              fresh[key][:occurrences] += 1
            end
          else
            fresh[key] = point.merge(occurrences: 1)
            known[key] = fingerprint
          end
        end
        [ fresh.values, conflicts ]
      end

      def point_attributes(point, series_id, now)
        payload = point.fetch(:payload)
        { project_id: @project.id, series_id: series_id, start_time_unix_nano: payload.fetch("startTimeUnixNano"),
          time_unix_nano: payload.fetch("timeUnixNano"), payload: payload,
          payload_digest: digest(payload), first_received_at: now }
      end

      def series_identity(series)
        identifying = series.except(:description)
        identifying[:resource] = identifying.fetch(:resource).except("droppedAttributesCount")
        identifying[:instrumentation_scope] = identifying.fetch(:instrumentation_scope).except("droppedAttributesCount")
        digest(identifying)
      end

      def digest(value)
        Digest::SHA256.hexdigest(JSON.generate(canonical(value)))
      end

      def canonical(value)
        case value
        when Hash then value.sort_by { |key, _| key.to_s }.to_h.transform_values { |item| canonical(item) }
        when Array then value.map { |item| canonical(item) }
        else value
        end
      end
    end
  end
end
