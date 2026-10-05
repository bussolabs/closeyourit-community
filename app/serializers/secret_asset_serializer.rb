# frozen_string_literal: true

class SecretAssetSerializer < ApplicationSerializer
  attributes :id, :name, :asset_type, :description, :archived_at, :created_at, :updated_at

  attribute :environment do |asset|
    asset.environment && { id: asset.environment_id, code: asset.environment.code, label: asset.environment.label }
  end

  attribute :shared, &:shared?

  attribute :current_version do |asset|
    version = asset.current_version
    version && { id: version.id, number: version.number, filename: version.original_filename,
                 content_type: version.content_type, byte_size: version.byte_size, fingerprint: version.fingerprint,
                 created_at: version.created_at }
  end
end
