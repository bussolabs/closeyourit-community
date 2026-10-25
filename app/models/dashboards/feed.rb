# frozen_string_literal: true

module Dashboards
  # One service's Open Dashboard: where to read it, the key to read it with, and the last good answer
  # (contract open-dashboard/v1). CYRA-1112
  class Feed < ApplicationRecord
    self.table_name = "dashboards_feeds"

    PATH = "/open-dashboard"

    belongs_to :project, class_name: "Projects::Project", inverse_of: :dashboard_feed

    encrypts :token

    validates :url, presence: true, length: { maximum: 2048 }
    validates :token, presence: true
    validates :project_id, uniqueness: true
    validate :public_https_url

    scope :enabled, -> { where(enabled: true) }

    def endpoint = "#{url.to_s.delete_suffix('/')}#{PATH}"

    private

    # No DNS lookup here: every read resolves and pins the address. This refuses what is wrong on its face.
    def public_https_url
      uri = URI.parse(url.to_s)
      private_ip = NetworkGuard.ip_literal?(uri.host.to_s) && NetworkGuard.blocked_address?(uri.host)
      valid = uri.scheme == "https" && uri.host.present? && uri.userinfo.nil? &&
              uri.query.nil? && uri.fragment.nil? && !private_ip
      errors.add(:url, :public_https) unless valid
    rescue URI::InvalidURIError
      errors.add(:url, :public_https)
    end
  end
end
