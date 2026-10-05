# frozen_string_literal: true

# Icona riutilizzabile per progetti e gruppi. Due sorgenti coesistono:
#   - `icon` (stringa): nome Lucide del set curato `Ui::Icons::NAMES`;
#   - `icon_image` (ActiveStorage): immagine caricata dall'utente.
# A display l'immagine ha la precedenza sull'icona (vedi `#icon_kind` e `Ui::EntityMarkComponent`).
# Limiti immagine più stretti degli allegati ticket (vedi App::Constants). Cfr. concern Attachable.
module Iconable
  extend ActiveSupport::Concern

  # Check condiviso (model validation + eventuale pre-attach), come Attachable.allowed?.
  def self.allowed_image?(content_type:, byte_size:)
    App::Constants::ICON_IMAGE_CONTENT_TYPES.include?(content_type) &&
      byte_size.to_i <= App::Constants::ICON_IMAGE_MAX_SIZE
  end

  included do
    has_one_attached :icon_image

    normalizes :icon, with: ->(value) { Ui::Icons.normalize(value) }

    validates :icon, inclusion: { in: Ui::Icons::NAMES }, allow_nil: true
    validate :icon_image_within_allowed_limits
  end

  # :image with an uploaded image, :glyph with an icon name, otherwise :none.
  def icon_kind
    return :image if icon_image.attached?
    return :glyph if icon.present?

    :none
  end

  private

  def icon_image_within_allowed_limits
    return unless icon_image.attached?

    blob = icon_image.blob
    return if blob.nil?

    errors.add(:icon_image, :too_large) if blob.byte_size.to_i > App::Constants::ICON_IMAGE_MAX_SIZE
    unless App::Constants::ICON_IMAGE_CONTENT_TYPES.include?(blob.content_type)
      errors.add(:icon_image, :invalid_type)
    end
  end
end
