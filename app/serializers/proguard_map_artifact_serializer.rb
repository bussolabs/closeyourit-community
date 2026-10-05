# frozen_string_literal: true

class ProguardMapArtifactSerializer < ApplicationSerializer
  attributes :id, :release, :dist, :debug_id, :created_at
  attribute(:kind) { "proguard_map" }
  attribute(:byte_size) { |artifact| artifact.blob.byte_size }
  attribute(:sha256) { |artifact| artifact.blob.sha256 }
end
