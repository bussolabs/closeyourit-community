# frozen_string_literal: true

# Gruppo di monitor uptime (contenitore ORG-LEVEL, canale CLI). Distinto da GroupSerializer
# (Projects::Group). public_status_enabled = status page pubblica del gruppo (opt-in).
class UptimeGroupSerializer < ApplicationSerializer
  attributes :id, :name, :slug, :color, :icon, :description, :public_status_enabled, :created_at
end
