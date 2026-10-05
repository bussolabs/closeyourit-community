# frozen_string_literal: true

module Projects
  # A move of a project or group to another organization; the unique partial index
  # keeps one active move per subject (CYRA-879).
  class Move < ApplicationRecord
    self.table_name = "projects_moves"

    belongs_to :subject, polymorphic: true
    belongs_to :source_organization, class_name: "Organizations::Organization"
    belongs_to :destination_organization, class_name: "Organizations::Organization"
    belongs_to :requested_by, class_name: "Accounts::Account", optional: true

    enum :status, { pending: 0, running: 1, succeeded: 2, failed: 3 }, default: :pending

    STALE_AFTER = 15.minutes

    scope :active, -> { where(status: %i[pending running]) }

    validate :different_organizations

    # A crashed worker, or a job lost before it ran, blocks the subject forever: fail it after STALE_AFTER (CYRA-879).
    def self.expire_stale!
      active.where(updated_at: ...STALE_AFTER.ago).update_all(status: statuses[:failed], error_message: "interrupted",
                                                                finished_at: Time.current)
    end

    private

    def different_organizations
      errors.add(:destination_organization, :invalid) if source_organization_id == destination_organization_id
    end
  end
end
