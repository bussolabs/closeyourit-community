# frozen_string_literal: true

module Agents
  module ConflictChecks
    # CYRA-1154 — main moved: one pending check per delivered proposal still waiting on this repository.
    # The unique index makes a repeated push delivery a no-op; the job then asks GitHub, 50 rows a round.
    class Schedule < ApplicationService
      SHA = /\A\h{40}\z/

      def initialize(repository:, main_sha:, commits:, now: Time.current)
        @repository = repository
        @main_sha = main_sha.to_s
        @commits = Array(commits).grep(Hash)
        @now = now
      end

      def call
        # A branch deletion carries forty zeros as its new head: there is nothing to merge with.
        return Result.ok([]) unless @main_sha.match?(SHA) && @main_sha.match?(/[^0]/)

        rows = waiting_candidates.map { |values| row(*values) }
        return Result.ok([]) if rows.empty?

        inserted = Agents::ConflictCheck.insert_all(rows, unique_by: :index_agents_conflict_checks_identity,
                                                          returning: %w[id])
        ids = inserted.rows.flatten
        Agents::ConflictCheckJob.perform_later if ids.any?
        Result.ok(ids)
      end

      private

      # The proposals a person or the staging closer is waiting on, minus those GitHub already closed.
      def waiting_candidates
        closed = @repository.pull_requests.where.not(state: :open).select(:number)
        ConflictChecks.waiting_workflows.joins(:review_candidate)
                      .where(agents_delivery_candidates: { repository_id: @repository.id })
                      .where.not(agents_delivery_candidates: { number: closed })
                      .pluck("agents_workflows.id", "agents_delivery_candidates.id",
                             "agents_delivery_candidates.repository_full_name", "agents_delivery_candidates.number")
      end

      def row(workflow_id, candidate_id, full_name, number)
        { workflow_id:, delivery_candidate_id: candidate_id, repository_full_name: full_name, number:,
          main_sha: @main_sha, state: "pending", attempts: 0,
          next_check_at: @now, main_titles: titles, main_commits_count: @commits.size,
          created_at: @now, updated_at: @now }
      end

      # First line of each commit message, without control characters and shortened: someone else wrote it.
      def titles
        @titles ||= @commits.filter_map { |commit| title_of(commit["message"]) }
                            .first(Agents::ConflictCheck::TITLES_LIMIT)
      end

      def title_of(message)
        return unless message.is_a?(String)

        message.lines.first.to_s.gsub(/[[:cntrl:]]/, " ").squish.truncate(Agents::ConflictCheck::TITLE_LENGTH).presence
      end
    end
  end
end
