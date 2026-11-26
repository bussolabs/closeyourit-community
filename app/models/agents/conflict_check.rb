# frozen_string_literal: true

module Agents
  # CYRA-1154 — one row per delivered pull request and main change: does the proposal still merge?
  # Only `pending` rows are read again; every other state is final and says how the check ended.
  class ConflictCheck < ApplicationRecord
    self.table_name = "agents_conflict_checks"

    # clean: still merges. sent_back: the work went back to the agent, once. gave_up: GitHub never
    # computed the answer. skipped: the work had already moved on, nothing to send back (`last_error_code`
    # says why). stopped: in conflict again after its resolution round, the work stopped with the reason.
    enum :state, { pending: 0, clean: 1, sent_back: 2, gave_up: 3, skipped: 4, stopped: 5 }, prefix: true

    # The titles the agent reads when it resumes: shortened and capped, they are someone else's text.
    TITLES_LIMIT = 20
    TITLE_LENGTH = 120

    belongs_to :workflow, class_name: "Agents::Workflow", inverse_of: :conflict_checks
    belongs_to :delivery_candidate, class_name: "Agents::DeliveryCandidate"

    validates :repository_full_name, :main_sha, presence: true
    validates :number, numericality: { only_integer: true, greater_than: 0 }

    scope :due, ->(now = Time.current) { state_pending.where(next_check_at: ..now) }

    # The landed changes not listed in `main_titles`, for the «and N more» line.
    def hidden_titles_count = [ main_commits_count - Array(main_titles).size, 0 ].max
  end
end
