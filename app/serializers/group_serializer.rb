# frozen_string_literal: true

# Gruppo (macro-progetto) per la CLI. Contenitore di progetti, senza ticket/key propri.
class GroupSerializer < ApplicationSerializer
  attributes :id, :name, :color, :icon, :created_at

  # URL (path-only) dell'icona-immagine caricata; nil se assente (vince comunque sull'icona FA).
  attribute :icon_image_url do |group|
    next nil unless group.icon_image.attached?

    Rails.application.routes.url_helpers.rails_blob_path(group.icon_image, only_path: true)
  end
end
