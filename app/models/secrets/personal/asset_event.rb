# frozen_string_literal: true

module Secrets
  module Personal
    # Audit append-only dei file segreti personali. Scoped a [account, organization]; l'asset è opzionale
    # (nullify al purge, così l'audit sopravvive). Nessun actor separato: l'account È l'attore. Mirror
    # account-scoped di Secrets::AssetEvent, ACTIONS senza delegated/undelegated (niente deleghe nel personale).
    class AssetEvent < ApplicationRecord
      ACTIONS = %w[uploaded downloaded rolled_back archived purged].freeze

      belongs_to :account, class_name: "Accounts::Account"
      belongs_to :organization, class_name: "Organizations::Organization"
      belongs_to :asset, class_name: "Secrets::Personal::Asset", optional: true

      attr_readonly :account_id, :organization_id, :asset_id, :action, :metadata
      validates :action, inclusion: { in: ACTIONS }
      scope :recent, -> { order(created_at: :desc) }

      def self.for(account:, organization:)
        where(account_id: account.id, organization_id: organization.id)
      end
    end
  end
end
