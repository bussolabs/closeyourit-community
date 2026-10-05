# frozen_string_literal: true

module Alerting
  # Join regola↔canale esterno: la regola consegna anche sui canali agganciati.
  class RuleChannel < ApplicationRecord
    self.table_name = "alerting_rule_channels"

    belongs_to :rule, class_name: "Alerting::Rule", inverse_of: :rule_channels
    belongs_to :channel, class_name: "Alerting::Channel", inverse_of: :rule_channels

    validates :channel_id, uniqueness: { scope: :rule_id }
    # Tenant-integrity: il canale deve appartenere alla stessa org della regola.
    validate :same_organization

    private

    def same_organization
      return if rule.nil? || channel.nil?

      errors.add(:channel, :cross_tenant) if rule.organization_id != channel.organization_id
    end
  end
end
