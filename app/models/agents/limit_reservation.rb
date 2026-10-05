# frozen_string_literal: true

module Agents
  # Decisione persistita per una nuova partenza. Anche le negazioni sono registrate: la stessa
  # idempotency key non cambia esito dopo un retry e non consuma due volte i contatori.
  class LimitReservation < ApplicationRecord
    OUTCOMES = %w[granted denied].freeze

    belongs_to :organization, class_name: "Organizations::Organization",
                              inverse_of: :agent_limit_reservations
    belongs_to :project, class_name: "Projects::Project", optional: true
    belongs_to :host, class_name: "Agents::Host", inverse_of: :limit_reservations, optional: true

    normalizes :runtime, with: ->(value) { value.to_s.strip.downcase }
    normalizes :idempotency_key, with: ->(value) { value.to_s.strip }

    validates :runtime, inclusion: { in: Agents::LimitPolicy::RUNTIMES }
    validates :idempotency_key, presence: true, length: { maximum: 255 },
                                uniqueness: { scope: :organization_id }
    validates :requested_ttl_seconds,
              numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 86_400 }
    validates :estimated_cost,
              numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: BigDecimal("9999999999.9999") },
              allow_nil: true
    validates :outcome, inclusion: { in: OUTCOMES }
    validate :tenant_integrity
    validate :decision_shape

    scope :active, lambda { |at = Agents::Limits::Clock.current|
      where(outcome: "granted").where("expires_at > ?", at)
    }

    def granted? = outcome == "granted"
    def expired?(at = Agents::Limits::Clock.current) = granted? && expires_at <= at

    private

    def tenant_integrity
      errors.add(:project, :invalid) if project && project.organization_id != organization_id
      errors.add(:host, :invalid) if host && host.organization_id != organization_id
    end

    def decision_shape
      if granted?
        errors.add(:expires_at, :blank) if expires_at.nil?
        errors.add(:denial_reason, :present) if denial_reason.present?
      else
        errors.add(:expires_at, :present) if expires_at.present?
        errors.add(:denial_reason, :blank) if denial_reason.blank?
      end
    end
  end
end
