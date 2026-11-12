# frozen_string_literal: true

module Agents
  module Staging
    # CYRA-1294 — whether the trial release of a commit really went through: the deploy to staging and its
    # smoke check, read from the jobs of the GitHub Actions runs on that commit. A green run is not enough:
    # a run whose two jobs were skipped stays green and released nothing.
    class DeployRun
      STEPS = %w[deploy-staging smoke-staging].freeze
      SUCCESS = "success"
      # Conclusions that say "it went wrong". `nil` is still running and is not one of them.
      FAILED_CONCLUSIONS = %w[failure cancelled timed_out startup_failure].freeze

      RELEASED = :released
      FAILED = :failed
      PENDING = :pending

      def self.outcome(...) = new(...).outcome

      def initialize(client:, installation:, repository:, commit:)
        @client = client
        @installation = installation
        @repository = repository
        @commit = commit
      end

      # A failed run only counts when no other run on the same commit released: a tag pushed again after a
      # cancelled run is a release that went fine.
      def outcome
        runs = release_runs
        return RELEASED if runs.any? { |succeeded, _| succeeded }
        return FAILED if runs.any? { |_, conclusion| FAILED_CONCLUSIONS.include?(conclusion) }

        PENDING
      end

      private

      # Only the runs that hold the two jobs: the names come from a called workflow, so they carry its prefix.
      def release_runs
        @client.workflow_runs(@installation, @repository, @commit).filter_map do |run|
          jobs = @client.workflow_run_jobs(@installation, @repository, run["id"])
          ours = jobs.select { |job| STEPS.include?(name_tail(job["name"])) }
          next if ours.empty?

          succeeded = STEPS.all? do |step|
            ours.any? { |job| name_tail(job["name"]) == step && job["conclusion"] == SUCCESS }
          end
          [ succeeded, run["conclusion"] ]
        end
      end

      def name_tail(name) = name.to_s.split("/").last.to_s.strip
    end
  end
end
