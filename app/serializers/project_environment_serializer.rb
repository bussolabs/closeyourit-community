# frozen_string_literal: true

# Riga join Connections::ProjectEnvironment con le capability [servers/uptime/secrets] per la coppia
# (progetto, ambiente): l'OVERRIDE esplicito del progetto (nil = eredita il default dell'ambiente) e il
# valore RISOLTO effettivamente in vigore. Usato dal canale CLI (override capabilities).
class ProjectEnvironmentSerializer < ApplicationSerializer
  attributes :environment_id

  attribute :code do |pe|
    pe.environment.code
  end
  attribute :label do |pe|
    pe.environment.label
  end

  # Override esplicito del progetto (nil = eredita il default dell'ambiente).
  attribute :servers_override do |pe|
    pe[:servers_enabled]
  end
  attribute :uptime_override do |pe|
    pe[:uptime_enabled]
  end
  attribute :secrets_override do |pe|
    pe[:secrets_enabled]
  end

  # Valore RISOLTO in vigore (default ereditato oppure override).
  attribute :servers_enabled do |pe|
    pe.servers_enabled?
  end
  attribute :uptime_enabled do |pe|
    pe.uptime_enabled?
  end
  attribute :secrets_enabled do |pe|
    pe.secrets_enabled?
  end
end
