# frozen_string_literal: true

class AgentAttemptSerializer < ApplicationSerializer
  # Identità + execution profile denormalizzato, tutto leggibile dalle colonne immutabili dell'attempt.
  # I pin dell'istruzione (`instruction_version`/`instruction_digest`) sono spariti coi typed agent: il pin
  # equivalente host-first è il `profile_digest` del lease, rivalidato dal claim e dalla consegna.
  attributes :id, :phase, :runtime, :status, :reviewer_runtime, :review_status,
             :started_at, :finished_at, :failure_reason,
             :host_id, :service_account_id, :skill_key, :sandbox, :permission_mode,
             :allowed_tools, :ttl, :bundle_digest, :bundle_ref

  attribute(:ticket) { |attempt| attempt.workflow.ticket.code }
end
