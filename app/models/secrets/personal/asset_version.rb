# frozen_string_literal: true

module Secrets
  module Personal
    # Versione immutabile di un file segreto personale: metadati + envelope crittografico (il DEK avvolto
    # dalla master key, gli IV/tag AES-GCM); il ciphertext vive su ActiveStorage. Mirror di
    # Secrets::AssetVersion, senza created_by (l'account è l'attore). L'AAD lega la versione al suo
    # contenuto (label "personal-secret-asset", distinta da quella di progetto = difesa in profondità).
    class AssetVersion < ApplicationRecord
      belongs_to :asset, class_name: "Secrets::Personal::Asset", foreign_key: :asset_id, inverse_of: :versions
      has_one_attached :ciphertext

      attr_readonly :asset_id, :number, :original_filename, :content_type, :byte_size, :wrapped_key,
                    :key_iv, :key_tag, :payload_iv, :payload_tag, :fingerprint
      validates :number, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: :asset_id }
      validates :original_filename, :content_type, :wrapped_key, :key_iv, :key_tag, :payload_iv,
                :payload_tag, :fingerprint, presence: true
      validates :byte_size, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 10.megabytes }

      def aad
        [ "personal-secret-asset", asset_id, "version", number, original_filename, content_type, byte_size ].join(":")
      end
    end
  end
end
