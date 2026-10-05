# frozen_string_literal: true

# Progetto per la CLI. `key` è l'identificatore umano usato dai comandi (--project KEY).
class ProjectSerializer < ApplicationSerializer
  attributes :id, :name, :key, :description, :color, :icon, :group_id, :created_at

  # URL (path-only) dell'icona-immagine caricata; nil se assente (vince comunque sull'icona FA).
  attribute :icon_image_url do |project|
    next nil unless project.icon_image.attached?

    Rails.application.routes.url_helpers.rails_blob_path(project.icon_image, only_path: true)
  end
end
