# frozen_string_literal: true

module Agents
  # Credenziale org-scoped con cui closeyourit-automator registra l'installazione (`POST /hosts`).
  # Non autorizza pull/report operativi. Segreto mostrato UNA volta; in DB solo digest SHA-256.
  # La generazione vive in Agents::Tokens::Issue (mai in callback). Pattern Servers::EnrollmentToken
  # (prefisso cyi_a_ invece di cyi_s_).
  class Token < ApplicationRecord
    belongs_to :organization,
               class_name: "Organizations::Organization",
               inverse_of: :agent_tokens
    belongs_to :created_by,
               class_name: "Accounts::Account",
               optional: true

    normalizes :name, with: ->(value) { value.to_s.strip }

    validates :name, presence: true, uniqueness: { scope: :organization_id }
    validates :token_digest, presence: true, uniqueness: true
    validates :token_prefix, presence: true

    scope :active, -> { where(revoked_at: nil) }

    def revoked? = revoked_at.present?

    # Debounce dell'aggiornamento di last_used_at (non bloccare l'hot path con una write a ogni fetch).
    def stale_usage?(threshold: 1.minute)
      last_used_at.nil? || last_used_at < threshold.ago
    end
  end
end
