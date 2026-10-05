# frozen_string_literal: true

module Secrets
  class AssetEvent < ApplicationRecord
    self.table_name = "secrets_asset_events"
    # "denied" (CYRA-666) e' l'unica azione che NON descrive qualcosa di avvenuto: registra un tentativo
    # fermato dal confine ambienti. Serve perche' un tentativo di scaricare una chiave privata di
    # produzione e' esattamente l'evento che si vuole ritrovare, e finora sui file non lasciava traccia
    # mentre sui valori si'. Un denied puo' non avere asset: il rifiuto sul caricamento avviene prima
    # che il file esista (asset_id e' nullable, belongs_to :asset e' optional).
    ACTIONS = %w[uploaded downloaded rolled_back archived purged delegated undelegated denied].freeze

    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :asset, class_name: "Secrets::Asset", optional: true
    belongs_to :project, class_name: "Projects::Project", optional: true
    belongs_to :environment, class_name: "Types::Environment", optional: true
    belongs_to :actor, class_name: "Accounts::Account", optional: true
    attr_readonly :organization_id, :asset_id, :project_id, :environment_id, :actor_id, :action, :metadata
    validates :action, inclusion: { in: ACTIONS }
    scope :recent, -> { order(created_at: :desc) }
  end
end
