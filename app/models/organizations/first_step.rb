# frozen_string_literal: true

module Organizations
  # The day an organization took one of its first steps (CYRA-1159). One row per step, written once:
  # a repeat never moves the first day, so a reopened ticket keeps its step ticked.
  class FirstStep < ApplicationRecord
    self.table_name = "organization_first_steps"

    STEPS = %w[first_error alert_rule invitation telegram ticket_closed].freeze

    belongs_to :organization, class_name: "Organizations::Organization", inverse_of: :first_steps

    validates :step, inclusion: { in: STEPS }

    # What the services call: a step that cannot be written never breaks the action that took it. The
    # savepoint keeps a failed insert from aborting the caller's transaction; the step is logged and lost.
    def self.record(step, organization_ids:, at: Time.current)
      step = step.to_s
      raise ArgumentError, "unknown first step: #{step}" unless STEPS.include?(step)

      transaction(requires_new: true) { record!(step, organization_ids:, at:) }
    rescue ActiveRecord::ActiveRecordError => e
      Rails.logger.warn("CYRA-1159 — first step #{step} not recorded: #{e.class}: #{e.message}")
      nil
    end

    # Insert if absent, one statement: the hot paths (error ingest, ticket close) pay one insert, never
    # a read first, and a repeat never moves the first day.
    def self.record!(step, organization_ids:, at: Time.current)
      step = step.to_s
      raise ArgumentError, "unknown first step: #{step}" unless STEPS.include?(step)

      ids = Array(organization_ids).compact.uniq
      return if ids.empty?

      insert_all(ids.map { |id| { organization_id: id, step: step, reached_at: at } },
                 unique_by: %i[organization_id step])
    end
  end
end
