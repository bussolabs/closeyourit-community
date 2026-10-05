# frozen_string_literal: true

class SourceMapArtifactSerializer < ApplicationSerializer
  attributes :id, :release, :dist, :generated_file, :debug_id, :created_at
  attribute(:kind) { "source_map" }
  attribute(:byte_size) { |artifact| artifact.blob.byte_size }
  attribute(:sha256) { |artifact| artifact.blob.sha256 }
end
