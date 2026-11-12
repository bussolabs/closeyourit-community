# frozen_string_literal: true

# Progetto per la CLI. `key` è l'identificatore umano usato dai comandi (--project KEY).
class ProjectSerializer < ApplicationSerializer
  attributes :id, :name, :key, :description, :color, :icon, :group_id, :created_at

  # URL (path-only) dell'icona-immagine caricata; nil se assente (vince comunque sull'icona FA).
  attribute :icon_image_url do |project|
    next nil unless project.icon_image.attached?

    Rails.application.routes.url_helpers.rails_blob_path(project.icon_image, only_path: true)
  end

  # CYRA-1303 — where and as whom the work is tried on staging, for whoever runs a proof there. The password
  # is never here: it is the named secret of the project's staging vault. nil when no link is set.
  attribute :test_access do |project|
    next nil if project.test_access_url.blank?

    { url: project.test_access_url, username: project.test_access_username,
      password_secret: Projects::TestAccess::SavePassword::NAME,
      environment: Projects::TestAccess::SavePassword::ENVIRONMENT }
  end
end
