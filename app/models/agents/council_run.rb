# frozen_string_literal: true

module Agents
  # One council slice: the proposals and votes of Claude and Codex on one project (CYRA-1133).
  class CouncilRun < ApplicationRecord
    STATUSES = %w[running completed failed].freeze
    FAILURE_KINDS = %w[quota auth session not_mapped abandoned invalid].freeze

    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :project, class_name: "Projects::Project"
    belongs_to :host, class_name: "Agents::Host"
    has_many :proposals, class_name: "Agents::CouncilProposal", inverse_of: :council_run, dependent: :destroy

    validates :status, inclusion: { in: STATUSES }
    validates :mode, inclusion: { in: Agents::Council::MODES }
    validates :failure_kind, inclusion: { in: FAILURE_KINDS }, allow_nil: true
    validates :started_at, presence: true

    scope :running, -> { where(status: "running") }
  end
end
