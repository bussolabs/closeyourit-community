# frozen_string_literal: true

# Canale esterno di alerting (canale CLI). MAI il config grezzo (secret): la destinazione è esposta
# come `target` umano (l'URL del webhook).
class AlertChannelSerializer < ApplicationSerializer
  attributes :id, :name, :kind, :enabled, :created_at

  attribute :target do |channel|
    channel.webhook_url
  end
end
