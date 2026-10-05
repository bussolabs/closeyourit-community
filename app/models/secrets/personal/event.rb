# frozen_string_literal: true

module Secrets
  module Personal
    # Audit append-only del vault personale: chi legge/modifica i propri secret. Immutabile (attr_readonly),
    # emesso via Secrets::Personal::RecordEvent dai punti di lettura (bundle CLI + endpoint reveal Member,
    # CYRA-204 — la lettura web porta `metadata.source: "web"` + il `name` della variabile letta) e di
    # mutazione (Set/Delete/Import). `name` è il nome del secret per set/deleted e per il reveal web; nil
    # per gli eventi bundle-level (read/imported) che portano il conteggio in `metadata`. Nessun `synced`
    # (il personale non si sincronizza), nessuna colonna actor (account_id È l'attore).
    class Event < ApplicationRecord
      ACTIONS = %w[read set deleted imported].freeze

      belongs_to :account, class_name: "Accounts::Account"
      belongs_to :organization, class_name: "Organizations::Organization"

      attr_readonly :account_id, :organization_id, :action, :name, :metadata

      validates :action, inclusion: { in: ACTIONS }

      scope :recent, -> { order(created_at: :desc) }

      # Eventi dell'account nell'org.
      def self.for(account:, organization:)
        where(account_id: account.id, organization_id: organization.id)
      end
    end
  end
end
