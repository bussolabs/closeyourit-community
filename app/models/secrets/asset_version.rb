# frozen_string_literal: true

module Secrets
  class AssetVersion < ApplicationRecord
    self.table_name = "secrets_asset_versions"

    belongs_to :asset, class_name: "Secrets::Asset", inverse_of: :versions
    belongs_to :created_by, class_name: "Accounts::Account", optional: true
    has_one_attached :ciphertext

    attr_readonly :asset_id, :number, :original_filename, :content_type, :byte_size, :wrapped_key,
                  :key_iv, :key_tag, :payload_iv, :payload_tag, :fingerprint, :created_by_id
    validates :number, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: :asset_id }
    validates :original_filename, :content_type, :wrapped_key, :key_iv, :key_tag, :payload_iv,
              :payload_tag, :fingerprint, presence: true
    validates :byte_size, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 10.megabytes }

    def aad
      [ "secret-asset", asset_id, "version", number, original_filename, content_type, byte_size ].join(":")
    end
  end
end
