# frozen_string_literal: true

module Artifacts
  module NativeSymbols
    class Upload < ApplicationService
      Outcome = Data.define(:artifact, :duplicate)

      def initialize(project:, account:, metadata:, object_base64:)
        @project, @account, @metadata, @object_base64 = project, account, metadata, object_base64
      end

      def call
        requested = Identity.call(metadata: @metadata)
        raise Rejected, "invalid_native_object" unless @object_base64.is_a?(String) && @object_base64.bytesize <= Processor::MAX_REQUEST
        begin
          bytes = Base64.strict_decode64(@object_base64)
        rescue ArgumentError
          raise Rejected, "invalid_native_object"
        end
        raise Rejected, "invalid_native_object" unless Base64.strict_encode64(bytes) == @object_base64
        inspected = Processor.call(bytes: bytes, expected: requested, addresses: [])
        @identity = Identity.call(metadata: inspected.fetch("objects").fetch(inspected.fetch("selected")))
        @identity_digest = Digest::SHA256.hexdigest(@identity.to_json)
        @digest = Digest::SHA256.hexdigest(bytes)
        blob, duplicate = reserve(bytes.bytesize)
        if duplicate
          Artifacts::NativeBackfillJob.perform_later(project_id: @project.id, native_symbol_id: duplicate.id)
          return Outcome.new(artifact: duplicate, duplicate: true)
        end
        artifact = nil
        duplicate = false
        blob.with_lock do
          Timeout.timeout(15, Unavailable, "Artifact storage deadline exceeded") do
            blob.service.upload(blob.key, StringIO.new(bytes), content_type: "application/octet-stream")
          end
          @project.with_lock do
            artifact = existing
            if artifact
              compare!(artifact)
              duplicate = true
            else
              artifact = @project.native_symbol_artifacts.create!(**@identity, created_by: @account, blob: blob, identity_sha256: @identity_digest, unreferenced_since: Time.current)
            end
            blob.update!(reserved_until: Time.current)
          end
        end
        Artifacts::NativeBackfillJob.perform_later(project_id: @project.id, native_symbol_id: artifact.id)
        Outcome.new(artifact: artifact, duplicate: duplicate)
      rescue ActiveStorage::Error, IOError, SystemCallError
        raise Unavailable, "Artifact storage is unavailable"
      end

      private

      def existing
        @project.native_symbol_artifacts.includes(:blob).find_by(identity_sha256: @identity_digest)
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
