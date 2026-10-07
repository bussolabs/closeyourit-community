module Coworkers
  # An app a Puck may use (CYRA-1014): GitHub through the organization's GitHub App, or a remote MCP
  # server. The token is encrypted and only Rails ever sends it; the model sees tool names only.
  class Connection < ApplicationRecord
    self.table_name = "coworkers_connections"
    PROVIDERS = %w[github mcp].freeze
    ACCESS = %w[read write].freeze
    MAX_TOOLS = 30

    belongs_to :puck, class_name: "Coworkers::Puck"
    encrypts :token

    validates :provider, inclusion: { in: PROVIDERS }
    validates :access, inclusion: { in: ACCESS }
    validates :name, presence: true, length: { maximum: 80 }
    validate :safe_url, if: -> { provider == "mcp" }

    # Tool names the runtime accepts are lowercase letters and underscores only.
    def prefix = "app_#{id.delete('-').first(6).tr('0-9', 'a-j')}_"
    def write? = access == "write"

    private

    def safe_url
      errors.add(:url, :invalid) unless url.to_s.start_with?("https://") && NetworkGuard.safe_url?(url)
    end
  end
end
