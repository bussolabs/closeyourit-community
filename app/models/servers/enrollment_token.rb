# frozen_string_literal: true

module Servers
  # Credenziale universale org-scoped per gli agent (stile Beszel universal token): un segreto
  # condiviso dalla flotta, mostrato UNA volta alla creazione; in DB solo `token_digest` = SHA-256
  # (lookup O(1) sull'hot path; non bcrypt: il segreto è full-entropy). La generazione vive in
  # Servers::EnrollmentTokens::Issue (mai in callback) — qui solo persistenza.
  class EnrollmentToken < ApplicationRecord
    belongs_to :organization,
               class_name: "Organizations::Organization",
               inverse_of: :server_enrollment_tokens
    belongs_to :created_by,
               class_name: "Accounts::Account",
               optional: true
    # CYRA-469 — le macchine registrate con QUESTO codice. Il legame nasce all'enrollment
    # (Servers::RegisterHost) e sopravvive alla revoca del codice: :nullify così cancellare un
    # codice non porta via le macchine, restano solo senza codice attribuibile.
    has_many :hosts,
             class_name: "Servers::Host",
             foreign_key: :enrollment_token_id,
             inverse_of: :enrollment_token,
             dependent: :nullify

    normalizes :name, with: ->(value) { value.to_s.strip }

    validates :name, presence: true, uniqueness: { scope: :organization_id }
    validates :token_digest, presence: true, uniqueness: true
    validates :token_prefix, presence: true

    scope :active, -> { where(revoked_at: nil) }

    def revoked? = revoked_at.present?

    # Debounce dell'aggiornamento di last_used_at (non bloccare l'ingest con una write a ogni push).
    def stale_usage?(threshold: 1.minute)
      last_used_at.nil? || last_used_at < threshold.ago
    end
  end
end
