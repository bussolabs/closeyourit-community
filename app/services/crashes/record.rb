# frozen_string_literal: true

module Crashes
  class Record < ApplicationService
    Outcome = Data.define(:accepted, :duplicates, :rejected, :diagnostics, :report)

    def initialize(project:, event:, items:)
      @project, @event, @items = project, event, items
      @accepted = @duplicates = @rejected = 0
      @diagnostics = Hash.new(0)
    end

    def call
      event_id = @event["event_id"].to_s.downcase
      raise Rejected, "missing_event_identity" unless EVENT_ID.match?(event_id)
      @items.each_with_index do |item, index|
        if index >= MAX_FILES
          reject("too_many_attachments")
          next
        end
        begin
          validate_event_fields!
          decoded = Decode.call(header: item.fetch(:header), bytes: item.fetch(:bytes))
          admit(event_id, decoded)
        rescue Rejected => error
          reject(error.message)
        end
      end
      enqueue_symbolication if @report&.manifest.present?
      Outcome.new(accepted: @accepted, duplicates: @duplicates, rejected: @rejected, diagnostics: @diagnostics.to_h, report: @report)
    end

    private

    def enqueue_symbolication
      @project.error_events.where(event_id: @report.event_id, created_at: Errors::Retention.for(@project).days.ago..).limit(100).pluck(:id, :created_at).each do |id, created_at|
        Errors::SymbolicateJob.perform_later(project_id: @project.id, event_id: id, event_created_at: created_at.iso8601(6))
      end
    end

    def validate_event_fields!
      %w[release environment dist].each do |key|
        value = @event[key]
        next if value.nil?
        raise Rejected, "invalid_event_metadata" unless value.is_a?(String) && value.bytesize <= 1024 && !value.include?("\0")
      end
    end

    def reject(reason)
      @rejected += 1
      @diagnostics[reason] += 1
    end

    def admit(event_id, decoded)
      digest = Digest::SHA256.hexdigest(decoded.fetch(:bytes))
      blob = reserve(event_id, decoded, digest)
      return if blob.nil?

      blob.with_lock do
        Timeout.timeout(15, Unavailable, "Crash attachment storage deadline exceeded") do
          blob.service.upload(blob.key, StringIO.new(decoded.fetch(:bytes)), content_type: "application/octet-stream")
        end
        @project.with_lock do
          # Retention/deletion and competing deliveries use the same project admission lock.
          @report = @project.crash_reports.find_by(event_id: event_id)
          validate_metadata!(event_id, decoded[:manifest])
          @report = @project.crash_reports.find_or_create_by!(event_id: event_id) do |report|
            existing = @project.error_events.find_by(event_id: event_id)
            metadata = existing ? Identity.metadata(existing) : @event.slice("release", "environment", "dist")
            metadata = Errors::Ingest::Scrub.call(payload: metadata)
            report.release = metadata["release"].presence if metadata["release"].is_a?(String)
            report.environment = metadata["environment"].presence if metadata["environment"].is_a?(String)
            report.dist = metadata["dist"].presence if metadata["dist"].is_a?(String)
          end
          previous = @report.attachments.includes(:blob).find_by(filename: decoded.fetch(:filename))
          if previous
            compare(previous.blob, digest)
            blob.update!(reserved_until: Time.current)
            next
          end
          raise Rejected, "too_many_attachments" if @report.attachments.count >= MAX_FILES
          @report.attachments.create!(project: @project, blob: blob, filename: decoded.fetch(:filename), kind: decoded.fetch(:kind))
          @report.update!(manifest: decoded.fetch(:manifest)) if decoded[:manifest]
          blob.update!(reserved_until: Time.current)
          @accepted += 1
        end
      end
    rescue ActiveStorage::Error, IOError, SystemCallError
      raise Unavailable, "Crash attachment storage is unavailable"
    end

    def reserve(event_id, decoded, digest)
      @project.with_lock do
        @report = @project.crash_reports.find_by(event_id: event_id)
        validate_metadata!(event_id, decoded[:manifest])
        previous = @report&.attachments&.includes(:blob)&.find_by(filename: decoded.fetch(:filename))
        if previous
          compare(previous.blob, digest)
          next nil
        end
        raise Rejected, "too_many_attachments" if @report && @report.attachments.count >= MAX_FILES
        size = decoded.fetch(:bytes).bytesize
        raise Rejected, "project_storage_quota" if Blob.where(project_id: @project.id).sum(:byte_size) + size > MAX_PROJECT_BYTES
        Blob.create!(project_id: @project.id, key: "crashes/#{SecureRandom.hex(32)}", service_name: Rails.configuration.active_storage.service.to_s,
                     byte_size: size, sha256: digest, reserved_until: 1.hour.from_now)
      end
    end

    def validate_metadata!(event_id, manifest)
      existing = @project.error_events.find_by(event_id: event_id)
      [ existing && Identity.metadata(existing), @report&.attributes ].compact.each do |metadata|
        %w[release environment dist].each do |key|
          next unless @event.key?(key)
          value = Errors::Ingest::Scrub.call(payload: @event[key])
          raise Rejected, "event_metadata_conflict" unless value.presence == metadata[key].presence
        end
      end
      if manifest && !Identity.compatible_build?(existing&.payload || @event, manifest)
        raise Rejected, "event_build_conflict"
      end
    end

    def compare(previous, digest)
      raise Rejected, "attachment_identity_conflict" unless previous.sha256 == digest
      @duplicates += 1
    end
  end
end
