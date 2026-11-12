# frozen_string_literal: true

module Agents
  module Workflows
    # Where the project or its group asks for it, a release that passed staging stops before production
    # and waits for a person (CYRA-1278). The stop is a block, so it shows where people decide and Unblock
    # is the go-ahead; ProductionHold keeps the same rule on the queue.
    class RequestProductionApproval < ApplicationService
      KIND = "production_approval"
      PHASE = "closer_production"

      # Every release of these projects already waiting for production: used when the switch is turned on.
      def self.for_projects(projects)
        Agents::Workflow.joins(:ticket).where(ticketing_tickets: { project_id: projects.select(:id) })
                        .where(cancelled_at: nil, completed_at: nil, blocked_at: nil,
                               closer_production_approved_at: nil, closer_production_started_at: nil)
                        .where.not(closer_staging_verified_at: nil)
                        .find_each { |workflow| call(workflow:) }
      end

      def initialize(workflow:)
        @workflow = workflow
      end

      def call
        return false unless self.class.pending?(@workflow)

        Block.call(workflow: @workflow, phase: PHASE, kind: KIND, reason: KIND)
      end

      # The go-ahead is still owed: staging is proved, nobody said yes, production has not started.
      def self.pending?(workflow)
        !workflow.terminal? && workflow.closer_staging_verified_at? && !workflow.closer_production_approved_at? &&
          !workflow.closer_production_started_at? &&
          (workflow.ticket.project.production_approval_required_active? || BrowserProof.owed?(workflow))
      end
    end
  end
end
