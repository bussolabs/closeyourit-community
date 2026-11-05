# frozen_string_literal: true

module Agents
  module Workflows
    # Approved work whose pull request is merged and whose code already went out with a release proved
    # in production: the closers have nothing left to release. Without this a retried staging found the
    # work inside a stable tag, could not report a beta of its own, and waited for a person to press
    # «mark as released». This does the same, with the proved release as evidence.
    class CloseAlreadyReleased < ApplicationService
      def initialize(workflow:, client: nil, now: Time.current)
        @workflow = workflow
        @client = client
        @now = now
      end

      def call
        return Result.ok(nil) unless eligible?

        version, sha = released_code
        return Result.ok(nil) if sha.blank?
        return Result.ok(nil) unless contained?(sha)

        close!(version, sha)
      rescue Github::Client::Error
        Result.ok(nil)
      end

      private

      def client = @client ||= Github::Client.new

      def candidate = @workflow.review_candidate

      def eligible?
        !@workflow.terminal? && @workflow.autopilot_approved_at? && candidate&.head_sha.present? &&
          candidate.repository.present? && merged?
      end

      def merged?
        Github::PullRequest.state_merged.exists?(repository_id: candidate.repository_id, number: candidate.number)
      end

      def production_releases
        @workflow.ticket.project.releases.where(environment: Projects::Release::DEFAULT_ENVIRONMENT)
      end

      # A release proved in production carries its commit. Projects proved by "merge" record releases
      # without one: for them the latest stable tag is the evidence, read from GitHub.
      def released_code
        proved = production_releases.where.not(proved_at: nil).where.not(sha: nil).order(proved_at: :desc).first
        return [ proved.version, proved.sha ] if proved

        latest = production_releases.order(created_at: :desc).first
        return [ nil, nil ] unless latest&.version&.match?(/\Av?\d+\.\d+\.\d+\z/)

        [ latest.version, client.tag_commit(installation_id, candidate.repository_full_name, latest.version) ]
      end

      def installation_id = candidate.repository.github_installation_id

      def contained?(sha)
        client.commit_contained?(installation_id, candidate.repository_full_name, sha, candidate.head_sha)
      end

      def close!(version, sha)
        evidence = { "closed_by" => "already_released", "release" => version, "release_sha" => sha, "at" => @now }
        outcome = nil
        ApplicationRecord.transaction do
          @workflow.lock!
          return Result.ok(@workflow) if @workflow.terminal?

          state = @workflow.organization.ticket_statuses.active.category_done.ordered.first
          raise ActiveRecord::Rollback if state.nil?

          @workflow.probes.live.each { |probe| probe.update!(closed_at: @now, next_check_at: nil, evidence: probe.evidence.merge(evidence)) }
          @workflow.update!(completed_at: @now, blocked_at: nil, blocked_phase: nil, blocked_kind: nil, blocked_reason: nil)
          outcome = Ticketing::ChangeStatus.call(organization: @workflow.organization, ticket: @workflow.ticket,
                                                 status_id: state.id, channel: :workflow)
          # A prerequisite still open refuses the status change: then nothing is closed at all.
          raise ActiveRecord::Rollback if outcome.err?
        end
        outcome || Result.ok(nil)
      end
    end
  end
end
