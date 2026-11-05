# frozen_string_literal: true

module Projects
  # A failing test a person marked as already known, with the ticket that will fix it and an expiry
  # (CYRA-1165). Until `expires_on` (included) its failures arrive as known; after it, as new again.
  # Who marked it is kept like the retirement of a release; the foreign key nullifies it.
  class KnownFailure < ApplicationRecord
    self.table_name = "projects_known_failures"

    # The farthest expiry a person may choose: a known failure is a promise to fix, not a mute switch.
    MAX_VALIDITY = 180.days

    belongs_to :project, class_name: "Projects::Project", inverse_of: :known_failures
    belongs_to :test_case, class_name: "Projects::TestCase", inverse_of: :known_failure
    belongs_to :ticket, class_name: "Ticketing::Ticket", optional: true
    belongs_to :marked_by, class_name: "Accounts::Account", optional: true

    validates :expires_on, presence: true
    validates :test_case_id, uniqueness: true
    validate :expiry_within_reach, if: :expires_on_changed?

    scope :valid_on, ->(day) { where(expires_on: day..) }

    def valid_on?(day = Date.current) = expires_on.present? && expires_on >= day

    private

    def expiry_within_reach
      return if expires_on.blank?
      return if expires_on.between?(Date.current, MAX_VALIDITY.from_now.to_date)

      errors.add(:expires_on, :invalid)
    end
  end
end
