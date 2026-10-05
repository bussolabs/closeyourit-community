# frozen_string_literal: true

class EnvironmentSerializer < ApplicationSerializer
  # servers/uptime/secrets_enabled = DEFAULT di capability dell'ambiente (l'override per-progetto vive
  # sulla join, esposto da ProjectEnvironmentSerializer). Additivo: retro-compatibile coi client esistenti.
  attributes :id, :code, :label, :color, :position, :active, :servers_enabled, :uptime_enabled, :secrets_enabled
end
