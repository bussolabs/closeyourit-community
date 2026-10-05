module Accounts
  # Concessione device-flow (OAuth 2.0 Device Authorization Grant, RFC 8628) per il login della CLI.
  # Ciclo: pending → (browser) approved/denied → (poll) fulfilled. account/organization si valorizzano
  # all'approvazione (l'umano sceglie l'org); api_token al primo poll dopo l'approvazione (il segreto
  # non passa MAI dal browser, solo dalla CLI). Lifecycle nei service Accounts::Devices::*.
  class DeviceGrant < ApplicationRecord
    self.table_name = "accounts_device_grants"

    belongs_to :account,
               class_name: "Accounts::Account",
               optional: true
    belongs_to :organization,
               class_name: "Organizations::Organization",
               optional: true
    belongs_to :api_token,
               class_name: "Accounts::ApiToken",
               optional: true,
               inverse_of: :device_grants

    enum :status, { pending: 0, approved: 1, denied: 2, fulfilled: 3, expired: 4 }, default: :pending

    validates :device_code_digest, presence: true, uniqueness: true
    validates :user_code, presence: true, uniqueness: true
    validates :expires_at, presence: true

    # In attesa di approvazione e non scaduta (lookup per la pagina di approvazione browser).
    scope :live, -> { where(status: :pending).where("expires_at > ?", Time.current) }

    def expired_now? = expires_at <= Time.current
    def approvable? = pending? && !expired_now?
  end
end
