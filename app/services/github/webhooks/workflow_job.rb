# frozen_string_literal: true

module Github
  module Webhooks
    # The `workflow_job` event (action completed): saves the outcome of one finished CI job (CYRA-1164).
    # A repeated delivery updates the same row, recognised by the job id GitHub gives each attempt.
    # Skipped jobs never ran and carry no figure, so they are not stored.
    class WorkflowJob < Base
      SKIPPED = "skipped"

      def call
        return Result.ok(nil) unless value_at(@payload, "action") == "completed"
        return Result.ok(nil) if repository.nil?

        job = object_at(@payload, "workflow_job")
        attributes = run_attributes(job)
        return Result.ok(nil) if attributes.nil? || attributes[:conclusion] == SKIPPED

        ci_job = repository.ci_jobs.create_or_find_by!(workflow_name: text(job, "workflow_name").to_s,
                                                       job_name: text(job, "name"))
        Github::CiJobRun.upsert(attributes.merge(ci_job_id: ci_job.id), unique_by: :github_job_id)
        Result.ok(ci_job)
      end

      private

      def run_attributes(job)
        attributes = {
          github_job_id: integer(value_at(job, "id")),
          run_id: integer(value_at(job, "run_id")),
          run_attempt: integer(value_at(job, "run_attempt")) || 1,
          head_sha: text(job, "head_sha"),
          head_branch: text(job, "head_branch"),
          conclusion: text(job, "conclusion"),
          queued_at: time(value_at(job, "created_at")),
          started_at: time(value_at(job, "started_at")),
          completed_at: time(value_at(job, "completed_at"))
        }
        required = attributes.values_at(:github_job_id, :run_id, :head_sha, :conclusion, :completed_at)
        required.all? && text(job, "name") ? attributes : nil
      end

      def text(job, key)
        value_at(job, key).to_s.strip.truncate(Github::CiJob::NAME_LIMIT).presence
      end

      def integer(value)
        Integer(value, exception: false) if value.is_a?(Integer) || value.is_a?(String)
      end

      def time(value)
        Time.iso8601(value) if value.is_a?(String)
      rescue ArgumentError
        nil
      end
    end
  end
end
