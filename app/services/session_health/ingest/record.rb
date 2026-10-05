# frozen_string_literal: true

require "digest"

module SessionHealth
  module Ingest
    class Record < ApplicationService
      Result = Data.define(:accepted, :duplicates, :stale, :rejected)
      UPDATE_COLUMNS = %i[update_unix_nano sequence status errors_count duration abnormal_mechanism initialization_seen observed_update_count payload_digest updated_at].freeze

      def initialize(project:, items:)
        @project = project
        @items = items
      end

      def call
        return Result.new(accepted: 0, duplicates: 0, stale: 0, rejected: 0) if @items.empty?
        @project.with_lock { persist }
      end

      private

      def persist
        counts = { accepted: 0, duplicates: 0, stale: 0, rejected: 0 }
        sessions = @items.select { |item| item.fetch(:type) == "session" }.map { |item| item.fetch(:value) }
        aggregates = @items.select { |item| item.fetch(:type) == "sessions" }.map { |item| item.fetch(:value) }
        existing = @project.health_sessions.where(sid: sessions.filter_map { |item| item[:sid] }).index_by { |row| row.sid }
        changed = {}
        now = Time.current
        sessions.each do |item|
          sid = item[:sid] || SecureRandom.uuid
          previous = changed[sid] || existing[sid]&.attributes&.symbolize_keys
          digest = payload_digest(item)
          outcome = classify(previous, item, digest)
          counts[outcome] += 1
          next unless outcome == :accepted
          changed[sid] = session_row(previous, item, sid, digest, now)
        end
        Session.upsert_all(changed.values, unique_by: [ :project_id, :sid ], update_only: UPDATE_COLUMNS, record_timestamps: false) if changed.any?
        if aggregates.any?
          Aggregate.insert_all!(aggregates.map { |item| item.merge(project_id: @project.id, created_at: now, updated_at: now) })
          counts[:accepted] += aggregates.size
        end
        Result.new(**counts)
      end

      def payload_digest(item)
        snapshot = item.dup
        snapshot.delete(:update_unix_nano) unless item[:timestamp_provided]
        snapshot.delete(:sequence) unless item[:sequence_provided] || item[:timestamp_provided]
        Digest::SHA256.hexdigest(JSON.generate(snapshot.sort.to_h))
      end

      def classify(previous, item, digest)
        return :accepted unless previous
        return :rejected unless immutable_match?(previous, item)
        return :duplicates if previous[:payload_digest] == digest
        order = [ item[:sequence], item[:update_unix_nano] ] <=> [ previous[:sequence].to_i, previous[:update_unix_nano].to_i ]
        return :stale if order.negative?
        return :rejected if order.zero? || previous[:status] != "ok" || item[:errors] < previous[:errors_count].to_i
        :accepted
      end

      def immutable_match?(previous, item)
        previous[:release] == item[:release] && previous[:environment] == item[:environment] &&
          previous[:started_unix_nano].to_i == item[:started_unix_nano]
      end

      def session_row(previous, item, sid, digest, now)
        item.except(:errors, :timestamp_provided, :sequence_provided).merge(errors_count: item[:errors], id: previous&.fetch(:id) || SecureRandom.uuid, sid: sid, project_id: @project.id,
          initialization_seen: item[:initialization_seen] || previous&.fetch(:initialization_seen) || false,
          observed_update_count: previous ? previous.fetch(:observed_update_count) + 1 : 1,
          payload_digest: digest, created_at: previous&.fetch(:created_at) || now, updated_at: now)
      end
    end
  end
end
