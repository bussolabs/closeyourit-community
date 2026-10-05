# frozen_string_literal: true

module Agents
  # Vincolo autoritativo applicabile a tutta l'organizzazione, a un progetto, a un runtime o alla
  # loro intersezione. I livelli applicabili sono cumulativi: vince sempre il limite più restrittivo.
  class LimitPolicy < ApplicationRecord
    RUNTIMES = %w[claude shell codex].freeze
    COST_SCALE = 4
    MAX_COST = BigDecimal("9999999999.9999")

    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :project, class_name: "Projects::Project", optional: true
    has_many :usages, class_name: "Agents::LimitUsage", foreign_key: :policy_id,
                      inverse_of: :policy, dependent: :destroy

    normalizes :runtime, with: ->(value) { value.to_s.strip.downcase.presence }

    validates :runtime, inclusion: { in: RUNTIMES }, allow_nil: true
    validates :max_parallel, :max_daily_runs,
              numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
    validates :max_runtime_seconds,
              numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
    validates :max_age_seconds, numericality: { only_integer: true, greater_than: 0 }
    validates :max_daily_cost, numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
    validates :project_id, uniqueness: { scope: %i[organization_id runtime] }
    validate :project_belongs_to_organization
    validate :max_daily_cost_fits_storage

    scope :applicable_to, lambda { |organization:, project:, runtime:|
      relation = where(organization:)
      relation = relation.where(project_id: project ? [ nil, project.id ] : nil)
      relation.where(runtime: runtime.present? ? [ nil, runtime ] : nil)
    }

    private

    def project_belongs_to_organization
      return if project.nil? || project.organization_id == organization_id

      errors.add(:project, :invalid)
    end

    # Active Record arrotonda i decimal alla scala della colonna già durante il type cast. La
    # validazione deve quindi leggere l'input originale, altrimenti 0.00001 diventerebbe 0 e
    # supererebbe silenziosamente il gate applicativo.
    def max_daily_cost_fits_storage
      raw = max_daily_cost_before_type_cast
      return if raw.nil? || raw == ""

      parsed = BigDecimal(raw.to_s, exception: false)
      canonical = parsed&.finite? ? parsed.round(COST_SCALE) : nil
      return if parsed&.finite? && canonical == parsed && parsed.between?(0, MAX_COST)

      errors.add(:max_daily_cost, :invalid)
    end
  end
end
