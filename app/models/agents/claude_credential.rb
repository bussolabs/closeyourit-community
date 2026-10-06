# frozen_string_literal: true

module Agents
  # The Claude credential the organization's automator machines use (CYAU-224).
  class ClaudeCredential < ApplicationRecord
    include LentCredential

    # Token prefix → kind, and the variable the host injects into Claude sessions.
    KINDS = {
      "api_key" => { prefix: "sk-ant-api", env: "ANTHROPIC_API_KEY" },
      "oauth_token" => { prefix: "sk-ant-oat", env: "CLAUDE_CODE_OAUTH_TOKEN" }
    }.freeze

    before_validation :derive_kind

    validates :token, presence: true, format: { with: /\A[A-Za-z0-9_-]+\z/, allow_blank: true }
    validates :kind, inclusion: { in: KINDS.keys }

    def env_name = KINDS.fetch(kind)[:env]
    def oauth_token? = kind == "oauth_token"
    def served = { kind: kind, env: env_name, token: token }

    # The token must never reach a log or a console.
    def inspect
      "#<#{self.class.name} id: #{id.inspect} organization_id: #{organization_id.inspect} kind: #{kind.inspect}>"
    end

    private

    def derive_kind
      self.kind = KINDS.find { |_, spec| token.to_s.start_with?(spec[:prefix]) }&.first
    end
  end
end
