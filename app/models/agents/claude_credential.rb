# frozen_string_literal: true

module Agents
  # The Claude credential the organization's automator machines use (CYAU-224). CYRA-1052: one row is the
  # organization's (no host), others belong to one machine; each is pasted or linked from a vault secret.
  class ClaudeCredential < ApplicationRecord
    include LentCredential

    # Token prefix → kind, and the variable the host injects into Claude sessions.
    KINDS = {
      "api_key" => { prefix: "sk-ant-api", env: "ANTHROPIC_API_KEY" },
      "oauth_token" => { prefix: "sk-ant-oat", env: "CLAUDE_CODE_OAUTH_TOKEN" }
    }.freeze
    TOKEN_FORMAT = /\A[A-Za-z0-9_-]+\z/

    belongs_to :host, class_name: "Agents::Host", optional: true, inverse_of: :claude_credential
    # A personal secret is lent by its owner (`set_by`), and only while they belong to the organization.
    belongs_to :personal_variable, class_name: "Secrets::Personal::Variable", optional: true
    belongs_to :shared_value, class_name: "Secrets::Shared::Value", optional: true

    before_validation :derive_kind

    validates :organization_id, uniqueness: { scope: :host_id }
    validates :token, format: { with: TOKEN_FORMAT, allow_blank: true }
    validates :kind, inclusion: { in: KINDS.keys }
    validate :one_source
    validate :links_inside_organization

    def env_name = KINDS.fetch(kind)[:env]
    def oauth_token? = kind == "oauth_token"
    def linked? = personal_variable_id.present? || shared_value_id.present?

    # The form value of the linked secret, so the page shows which one is in use.
    def secret_ref
      return "personal:#{personal_variable_id}" if personal_variable_id
      "shared:#{shared_value_id}" if shared_value_id
    end

    # What the host receives, or nil when the source can no longer be served (a lender who left, a value
    # that is not a Claude credential any more): the caller then falls back to the next credential.
    def served
      value = resolved_token
      served_kind = kind_of(value)
      return nil if served_kind.nil? || !value.match?(TOKEN_FORMAT) || !lender_still_member?

      { kind: served_kind, env: KINDS.fetch(served_kind)[:env], token: value }
    end

    # The token must never reach a log or a console.
    def inspect
      "#<#{self.class.name} id: #{id.inspect} organization_id: #{organization_id.inspect} host_id: #{host_id.inspect} kind: #{kind.inspect}>"
    end

    private

    def resolved_token
      (personal_variable&.value || shared_value&.value || token).to_s.strip
    end

    def kind_of(value) = KINDS.find { |_, spec| value.start_with?(spec[:prefix]) }&.first

    def derive_kind
      self.kind = kind_of(resolved_token)
    end

    def lender_still_member?
      return true if personal_variable.nil?

      Connections::Membership.exists?(account_id: set_by_id, organization_id: organization_id)
    end

    def one_source
      sources = [ token.present?, personal_variable_id.present?, shared_value_id.present? ].count(true)
      errors.add(:token, :blank) if sources.zero?
      errors.add(:base, :invalid) if sources > 1
    end

    def links_inside_organization
      errors.add(:host, :invalid) if host && host.organization_id != organization_id
      if personal_variable && (personal_variable.organization_id != organization_id || personal_variable.account_id != set_by_id)
        errors.add(:personal_variable, :invalid)
      end
      errors.add(:shared_value, :invalid) if shared_value && shared_value.organization.id != organization_id
    end
  end
end
