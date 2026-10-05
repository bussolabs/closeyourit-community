# frozen_string_literal: true

# The exception belongs to uptime only, never to the shared webhook/network guard.
module DevelopmentLab
  PORTS = [ 31311, 31312, 31313 ].freeze

  def self.organization?(organization, development: Rails.env.development?)
    development && organization&.slug == "demo"
  end

  def self.address(uri, organization:, development: Rails.env.development?)
    return unless organization?(organization, development:)
    return unless uri.scheme == "http" && uri.host == "127.0.0.1" && PORTS.include?(uri.port)
    return unless uri.path == "/up" && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil?

    "127.0.0.1"
  end
end
