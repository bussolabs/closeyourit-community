# frozen_string_literal: true

module Artifacts
  module NativeSymbols
    class Read < ApplicationService
      def initialize(artifact:)
        @artifact = artifact
      end

      def call
        bytes = +""
        blob = @artifact.blob
        Timeout.timeout(10, Unavailable, "Artifact read deadline exceeded") do
          blob.service.download(blob.key) do |chunk|
            raise Unavailable, "Stored artifact exceeds its budget" if bytes.bytesize + chunk.bytesize > Processor::MAX_BINARY
            bytes << chunk
          end
        end
        raise Unavailable, "Stored artifact integrity mismatch" unless bytes.bytesize == blob.byte_size && Digest::SHA256.hexdigest(bytes) == blob.sha256
        bytes.force_encoding(Encoding::BINARY)
      rescue ActiveStorage::Error, IOError, SystemCallError
        raise Unavailable, "Artifact is unavailable"
      end
    end
  end
end
