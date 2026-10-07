module Coworkers
  # A person's computer connected with `cyi puck connect` (CYRA-1029). Only the token's digest is stored.
  class Device < ApplicationRecord
    self.table_name = "coworkers_devices"
    ONLINE_FOR = 30.seconds

    belongs_to :account, class_name: "Accounts::Account"
    belongs_to :organization, class_name: "Organizations::Organization"
    has_many :calls, class_name: "Coworkers::DeviceCall", dependent: :delete_all
    validates :name, presence: true, length: { maximum: 80 }

    scope :live, -> { where(revoked_at: nil) }

    def self.issue(account:, organization:, name:)
      secret = "cyi_d_#{SecureRandom.base58(40)}"
      device = create!(account: account, organization: organization, name: name, token_digest: digest(secret))
      [ device, secret ]
    end

    def self.digest(secret) = Digest::SHA256.hexdigest(secret.to_s)
    def self.authenticate(secret)
      live.find_by(token_digest: digest(secret)) if secret.to_s.start_with?("cyi_d_")
    end

    def online? = revoked_at.nil? && last_seen_at.present? && last_seen_at > ONLINE_FOR.ago
  end
end
