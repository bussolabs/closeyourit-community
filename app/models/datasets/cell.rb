# frozen_string_literal: true

module Datasets
  # Cella FOTO: una immagine per (riga, colonna kind=photo). Le celle scalari vivono nel jsonb della
  # riga; qui serve un record perché l'immagine è un blob ActiveStorage. Content-type/size validati sui
  # byte reali (allowlist raster, niente svg/html → stored XSS, come App::Constants::ICON_IMAGE_CONTENT_TYPES).
  class Cell < ApplicationRecord
    belongs_to :row,
               class_name: "Datasets::Row",
               inverse_of: :cells
    belongs_to :column,
               class_name: "Datasets::Column",
               inverse_of: :cells

    has_one_attached :image

    validates :column_id, uniqueness: { scope: :row_id }
    validate :column_is_photo
    validate :row_and_column_same_dataset
    validate :image_allowed

    # Check condiviso model-validation + pre-attach (pattern App::Constants concern Iconable/Attachable).
    def self.allowed?(content_type:, byte_size:)
      Datasets::Constants::IMAGE_CONTENT_TYPES.include?(content_type) &&
        byte_size.to_i.positive? && byte_size.to_i <= Datasets::Constants::IMAGE_MAX_SIZE
    end

    private

    def column_is_photo
      return if column.blank?

      errors.add(:column, :invalid) unless column.kind_photo?
    end

    # Tenant integrity: la colonna e la riga devono appartenere allo stesso dataset.
    def row_and_column_same_dataset
      return if row.blank? || column.blank?

      errors.add(:column, :invalid) if row.dataset_id != column.dataset_id
    end

    def image_allowed
      return unless image.attached?

      errors.add(:image, :invalid) unless self.class.allowed?(content_type: image.content_type, byte_size: image.byte_size)
    end
  end
end
