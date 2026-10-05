# frozen_string_literal: true

module Artifacts
  module ProguardMaps
    class Upload < ApplicationService
      Outcome = Data.define(:artifact, :duplicate)

      def initialize(project:, account:, metadata:, mapping:)
        @project, @account, @metadata, @mapping = project, account, metadata, mapping
      end

      def call
        @identity = Identity.call(metadata: @metadata)
        @identity_digest = Digest::SHA256.hexdigest(@identity.to_json)
        Processor.call(mapping: @mapping, stacktrace: [])
        bytes = @mapping.dup.force_encoding(Encoding::UTF_8)
        @digest = Digest::SHA256.hexdigest(bytes)
        blob, duplicate = reserve(bytes.bytesize)
        if duplicate
          Artifacts::ProguardBackfillJob.perform_later(project_id: @project.id, proguard_map_id: duplicate.id)
          return Outcome.new(artifact: duplicate, duplicate: true)
        end
        artifact = nil
        duplicate = false
        blob.with_lock do
          Timeout.timeout(15, Unavailable, "Artifact storage deadline exceeded") do
            blob.service.upload(blob.key, StringIO.new(bytes), content_type: "text/plain; charset=utf-8")
          end
          @project.with_lock do
            artifact = existing
            if artifact
              compare!(artifact)
              duplicate = true
            else
              artifact = @project.proguard_map_artifacts.create!(**@identity, created_by: @account, blob: blob, identity_sha256: @identity_digest, unreferenced_since: Time.current)
            end
            blob.update!(reserved_until: Time.current)
          end
        end
        Artifacts::ProguardBackfillJob.perform_later(project_id: @project.id, proguard_map_id: artifact.id)
        Outcome.new(artifact: artifact, duplicate: duplicate)
      rescue ActiveStorage::Error, IOError, SystemCallError
        raise Unavailable, "Artifact storage is unavailable"
      end

      private

      def existing
        @project.proguard_map_artifacts.includes(:blob).find_by(identity_sha256: @identity_digest)
      end

      def compare!(artifact)
        raise Conflict, "artifact_identity_conflict" unless artifact.blob.sha256 == @digest
      end

      def reserve(size)
        @project.with_lock do
          artifact = existing
          if artifact
            compare!(artifact)
            next [ nil, artifact ]
          end
          raise Rejected, "project_artifact_quota" if Blob.where(project_id: @project.id).sum(:byte_size) + size > MAX_PROJECT_BYTES
          blob = Blob.create!(project_id: @project.id, key: "artifacts/#{SecureRandom.hex(32)}", service_name: Rails.configuration.active_storage.service.to_s, byte_size: size, sha256: @digest, reserved_until: 1.hour.from_now)
          [ blob, nil ]
        end
      end
    end
  end
end
