# frozen_string_literal: true

module Secrets
  module Personal
    # File segreto PERSONALE cifrato, scoped a [account, organization] — gemello per-utente di
    # Secrets::Asset (che è per progetto/organizzazione). Struttura FLAT: nessun ambiente, nessuna
    # delega, nessun RBAC (ownership come Secrets::Personal::Variable / Todos::List). L'account è la
    # radice di tenancy E l'unico attore → nessun created_by. Il contenuto cifrato vive nelle versioni
    # (envelope AES-GCM riusata da Secrets::Assets::Crypto, ciphertext su ActiveStorage). asset_type è
    # generico (inferito dall'estensione dall'Upload): un vault personale ospita file arbitrari.
    class Asset < ApplicationRecord
      belongs_to :account, class_name: "Accounts::Account"
      belongs_to :organization, class_name: "Organizations::Organization"
      has_many :versions, class_name: "Secrets::Personal::AssetVersion",
               foreign_key: :asset_id, inverse_of: :asset, dependent: :destroy

      attr_readonly :account_id, :organization_id
      normalizes :name, with: ->(value) { value.to_s.strip }
      normalizes :description, with: ->(value) { value.to_s.strip.presence }

      validates :name, presence: true, uniqueness: { scope: %i[account_id organization_id] }
      validates :asset_type, presence: true

      scope :active, -> { where(archived_at: nil) }
      scope :ordered, -> { order(:name) }

      # File dell'account nell'org (posseduti). Anti-BOLA per find/destroy (pattern Secrets::Personal::Variable).
      def self.for(account:, organization:)
        where(account_id: account.id, organization_id: organization.id)
      end

      def archived? = archived_at.present?
      def current_version = versions.order(number: :desc).first
    end
  end
end
