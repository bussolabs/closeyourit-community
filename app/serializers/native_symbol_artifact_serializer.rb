# frozen_string_literal: true

class NativeSymbolArtifactSerializer < ApplicationSerializer
  attributes :id, :format, :architecture, :debug_id, :code_id, :created_at
  attribute(:kind) { "native_symbol" }
  attribute(:byte_size) { |artifact| artifact.blob.byte_size }
  attribute(:sha256) { |artifact| artifact.blob.sha256 }
end
