# frozen_string_literal: true

module Agents
  # CYAU-235 — a decision the supporter took: an answer, a plan approval or a hand-over to a person. Applied
  # decisions wait in "To review" until a person marks them seen; marking seen neither approves nor undoes.
  class SupporterDecision < ApplicationRecord
    TARGET_TYPES = %w[question plan].freeze
    OUTCOMES = %w[answered approved escalated].freeze

    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :workflow, class_name: "Agents::Workflow"
    belongs_to :seen_by, class_name: "Accounts::Account", optional: true

    validates :target_type, inclusion: { in: TARGET_TYPES }
    validates :outcome, inclusion: { in: OUTCOMES }
    validates :engine, inclusion: { in: Host::SUPPORTERS }
    validates :risk_score, inclusion: { in: Supporters::RiskScore::RANGE }
    validates :target_id, :target_digest, presence: true
    validates :target_digest, uniqueness: { scope: %i[target_type target_id] }

    scope :to_review, -> { where(seen_at: nil).where.not(outcome: "escalated") }

    def mark_seen!(by:) = update!(seen_at: Time.current, seen_by: by)
  end
end
