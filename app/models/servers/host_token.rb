# frozen_string_literal: true

module Servers
  class HostToken < ApplicationRecord
    belongs_to :host, class_name: "Servers::Host", inverse_of: :host_tokens

    validates :token_digest, :token_prefix, presence: true
    validates :token_digest, uniqueness: true

    scope :active, -> { where(revoked_at: nil) }

    def revoked? = revoked_at.present?
    def stale_usage?(threshold: 1.minute) = last_used_at.nil? || last_used_at < threshold.ago
  end
end
