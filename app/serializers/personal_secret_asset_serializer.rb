# frozen_string_literal: true

# File segreto personale per il canale CLI. MAI il ciphertext/contenuto: solo metadati. Flat — niente
# environment/shared/delegations (esistono solo negli asset di progetto/organizzazione).
class PersonalSecretAssetSerializer < ApplicationSerializer
  attributes :id, :name, :asset_type, :description, :archived_at, :created_at, :updated_at

  attribute :current_version do |asset|
    version = asset.current_version
    version && { id: version.id, number: version.number, filename: version.original_filename,
                 content_type: version.content_type, byte_size: version.byte_size,
                 fingerprint: version.fingerprint, created_at: version.created_at }
  end
end
