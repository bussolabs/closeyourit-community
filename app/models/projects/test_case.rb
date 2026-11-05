# frozen_string_literal: true

module Projects
  # One test of a project, identified by its file and full name (CYRA-1165). The identity is a digest
  # of the two, so the history of a test accumulates run after run; a renamed or moved test starts a
  # new one, and the old name stays until the retention drops it.
  class TestCase < ApplicationRecord
    self.table_name = "projects_test_cases"

    STATUSES = %w[passed failed skipped].freeze

    belongs_to :project, class_name: "Projects::Project", inverse_of: :test_cases

    has_many :results, class_name: "Projects::TestResult", foreign_key: :test_case_id, inverse_of: :test_case,
                       dependent: :delete_all
    has_one :known_failure, class_name: "Projects::KnownFailure", foreign_key: :test_case_id, inverse_of: :test_case,
                            dependent: :delete

    validates :name, presence: true
    validates :identity_digest, presence: true, uniqueness: { scope: :project_id }
    validates :last_status, inclusion: { in: STATUSES }, allow_nil: true

    scope :flaky, -> { where.not(flaky_at: nil) }
    scope :failing, -> { where(last_status: "failed") }
    scope :with_known_failure, ->(on = Date.current) { where(id: KnownFailure.valid_on(on).select(:test_case_id)) }
    scope :recent_first, -> { order(Arel.sql("last_run_at DESC NULLS LAST"), :name) }

    def self.digest_for(file, name)
      Digest::SHA256.hexdigest("#{file}\u0000#{name}")
    end

    def flaky? = flaky_at.present?
  end
end
