# frozen_string_literal: true

module Agents
  module Candidates
    # CYRA-1346, CYRA-1347 — a delivery already verified and left in front of a person is looked at again.
    #
    # The verdict on a delivery is written once, and what happens to the work is decided in that moment.
    # Nothing came back afterwards: a pull request that fell into conflict with main while it waited, or
    # one in a repository with no checks, stayed there until a person noticed. Here the same two answers
    # the first look gives are given again: in conflict → back to the agent for the resolution round (or
    # stopped with the reason, if that round was used); otherwise the automatic yes is asked again.
    #
    # A few rows per pass, and each row rests for hours after a look: every look is a call to GitHub, and
    # the delivery gates write in the ticket's history each time they run.
    class RecheckWaiting < ApplicationService
      BATCH = 10
      REST = 6.hours
      MOVING_ON = %w[verified_passing verified_none_configured].freeze

      def initialize(client: nil, now: Time.current)
        @client = client
        @now = now
      end

      def call
        looked = waiting.count { |workflow| look_at(workflow) }
        Result.ok(looked)
      end

      private

      def client = @client ||= Github::Client.new

      def waiting
        Agents::Workflow.where.not(review_candidate_id: nil).where.not(candidate_verified_at: nil)
                        .where(autopilot_approved_at: nil, completed_at: nil, cancelled_at: nil, blocked_at: nil)
                        .order(:candidate_verified_at).limit(BATCH * 5)
                        .reject { |workflow| Rails.cache.exist?(key(workflow)) }.first(BATCH)
      end

      def key(workflow) = "agents:candidates:recheck:#{workflow.review_candidate_id}"

      # One row that explodes or a GitHub that does not answer leaves the work where it was.
      def look_at(workflow)
        Rails.cache.write(key(workflow), true, expires_in: REST)
        candidate = Agents::DeliveryCandidate.find_by(id: workflow.review_candidate_id)
        return false unless candidate&.repository && candidate.state.in?(MOVING_ON)
        return false if held_by_person?(workflow)

        state = client.pull_request_state(candidate.repository.github_installation_id, candidate.repository_full_name,
                                          candidate.number)
        state[:mergeable].to_s.upcase == "CONFLICTING" ? conflict!(workflow, candidate) : approve(workflow, candidate)
        true
      rescue StandardError => e
        Rails.logger.error("Agents::Candidates::RecheckWaiting: #{workflow.id} #{e.class}: #{e.message}")
        false
      end

      # A person who looked at this delivery and said no keeps the last word: nothing moves it by itself.
      def held_by_person?(workflow)
        Ticketing::Event.where(ticket_id: workflow.ticket_id, action: "review_rejected")
                        .exists?([ "created_at >= ?", workflow.candidate_verified_at ])
      end

      def conflict!(workflow, candidate)
        if workflow.conflict_resolution_requested_at.nil?
          workflow.send_phase_back_to_work!("autopilot")
          workflow.reload.update!(conflict_resolution_requested_at: @now, **Agents::Workflow.cleared_block(@now))
        else
          Agents::Workflows::BlockExhaustedPhase.call(
            workflow:, phase: "autopilot", source: "candidate_check",
            reason: "merge_conflict on #{candidate.repository_full_name}##{candidate.number}"
          )
        end
      end

      def approve(workflow, candidate)
        Agents::Workflows::AutoApprove.call(workflow:, candidate:, client:)
      end
    end
  end
end
