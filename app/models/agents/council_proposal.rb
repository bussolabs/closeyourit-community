# frozen_string_literal: true

module Agents
  # A council proposal with the other engine's vote and what the server made of it (CYRA-1133).
  class CouncilProposal < ApplicationRecord
    OUTCOMES = %w[invalid rejected duplicate unchecked ticket idea dry_ticket dry_idea create_failed].freeze

    belongs_to :council_run, class_name: "Agents::CouncilRun", inverse_of: :proposals
    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :project, class_name: "Projects::Project"
    belongs_to :ticket, class_name: "Ticketing::Ticket", optional: true
    belongs_to :idea, class_name: "Ideas::Idea", optional: true

    validates :ref, :proposer, :title, :problem, presence: true
    validates :outcome, inclusion: { in: OUTCOMES }

    def self.ticket_ids_for(organization) = where(organization:).where.not(ticket_id: nil).pluck(:ticket_id)
  end
end
