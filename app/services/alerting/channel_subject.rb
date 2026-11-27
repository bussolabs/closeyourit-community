# frozen_string_literal: true

module Alerting
  # Re-read ownership and activation along the subject's domain parents before every attempt.
  # Snapshot labels never authorize delivery; unknown ownership fails closed. CYRA-1227
  class ChannelSubject
    PARENTS = %i[monitor site idea dataset cluster team project organization].freeze

    def self.authorized?(subject, rule:, project_id:)
      return false unless subject && rule

      records = ancestry(subject)
      return false if records.empty? || records.any? { |record| inactive?(record) }

      organization = records.find { |record| record.is_a?(Organizations::Organization) }
      project = records.find { |record| record.is_a?(Projects::Project) }
      organization&.id == rule.organization_id && project&.id == project_id &&
        (rule.project_id.nil? || rule.project_id == project&.id)
    end

    def self.ancestry(subject)
      records = []
      current = subject
      while current && !records.include?(current)
        records << current
        break if current.is_a?(Organizations::Organization)

        parent = PARENTS.find { |name| current.class.reflect_on_association(name) }
        current = current.public_send(parent) if parent
        break unless parent
      end
      records
    end
    private_class_method :ancestry

    def self.inactive?(record)
      (record.has_attribute?(:active) && !record.active?) ||
        (record.has_attribute?(:enabled) && !record.enabled?) ||
        (record.has_attribute?(:revoked_at) && record.revoked_at.present?) ||
        (record.respond_to?(:status_paused?) && record.status_paused?)
    end
    private_class_method :inactive?
  end
end
