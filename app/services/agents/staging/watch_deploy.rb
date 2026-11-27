# frozen_string_literal: true

module Agents
  module Staging
    # CYRA-1366 — with the project's trial-release rule off, the merge alone opens production, and the trial
    # release keeps being watched until production starts. A failed or cancelled one, with no other run on
    # the same commit gone fine, stops the work before production. One never seen stops nothing.
    class WatchDeploy < ApplicationService
      FAILED_CODE = "staging_run_failed"

      def initialize(workflow:, client: nil, now: Time.current)
        @workflow = workflow
        @client = client
        @now = now
      end

      def call
        return Result.ok(@workflow) unless self.class.watching?(@workflow)

        candidate = @workflow.review_candidate
        declared = VerifyMerge.declared_commit(@workflow)
        return stop_watching if candidate&.repository.nil? || declared.blank? || overdue?

        case DeployRun.outcome(client:, installation: candidate.repository.github_installation_id,
                               repository: candidate.repository_full_name, commit: declared)
        when DeployRun::FAILED then block!
        when DeployRun::RELEASED then stop_watching
        else check_again
        end
      rescue Github::Client::Error
        check_again
      end

      # Verified, armed and not yet in production: past that, stopping it is no longer in time.
      def self.watching?(workflow)
        workflow.closer_staging_verified_at? && workflow.closer_staging_next_check_at? &&
          !workflow.blocked_at? && !workflow.terminal? &&
          workflow.closer_production_started_at.nil? && workflow.closer_production_completed_at.nil?
      end

      private

      def client = @client ||= Github::Client.new

      # The same window the rule-on check waits for: past it the run is not coming, and is not looked for.
      def overdue? = @workflow.closer_staging_completed_at < @now - VerifyMerge::DEPLOY_GRACE_WINDOW

      def check_again
        return stop_watching if overdue?

        @workflow.update!(closer_staging_next_check_at: @now + VerifyMerge::DEPLOY_RETRY_EVERY)
        Result.ok(@workflow)
      end

      def stop_watching
        @workflow.update!(closer_staging_next_check_at: nil)
        Result.ok(@workflow)
      end

      # Under the lock: a production claimed while GitHub was being read is no longer stopped from here.
      def block!
        @workflow.with_lock do
          next unless self.class.watching?(@workflow)

          @workflow.update!(closer_staging_next_check_at: nil, closer_staging_last_error_code: FAILED_CODE)
          Agents::Workflows::BlockExhaustedPhase.call(
            workflow: @workflow, phase: "closer_production", source: "staging_proof", reason: FAILED_CODE,
            kind: VerifyMerge::DEPLOY_STOP_KIND
          )
        end
        Result.ok(@workflow)
      end
    end
  end
end
