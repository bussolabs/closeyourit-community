# frozen_string_literal: true

module Agents
  module ConflictChecks
    # CYRA-1154 — asks GitHub whether the delivered proposal still merges. MERGEABLE closes the row,
    # CONFLICTING sends the work back, and UNKNOWN (GitHub computes it lazily) waits a little longer.
    #
    # Two reads of the same row can overlap (a round that outlived its concurrency lease, a manual run):
    # every write here is conditional on the row still being pending at the attempt it read, so a late
    # MERGEABLE never overwrites the send back, and two empty reads overlapping count as one.
    class Run < ApplicationService
      # Five reads at most, the waits between them doubling from 30 seconds. After the fifth empty read the
      # check gives up and the ticket stays put: the six-hour recheck and the merge at staging release still
      # catch a real conflict, as before.
      MAX_READS = 5
      FIRST_DELAY = 30.seconds
      # Authoritative answers: asking again would get the same one.
      DEFINITIVE_STATUSES = %i[unauthorized forbidden not_found].freeze

      # The wait after the read number `read` (1-based) gave no answer.
      def self.delay_after(read) = FIRST_DELAY * (2**(read - 1))

      def initialize(check:, client: nil, now: Time.current)
        @check = check
        @client = client
        @now = now
      end

      def call
        return Result.ok(@check) unless @check.state_pending?

        # Work that already moved on, or a repository that no longer syncs, costs no call to GitHub.
        skip = ConflictChecks.skip_reason(@check.workflow, @check)
        return close!(:skipped, skip) if skip

        repository = @check.delivery_candidate.repository
        decide(client.pull_request_state(repository.github_installation_id, @check.repository_full_name,
                                         @check.number))
      rescue Github::Client::Error => e
        DEFINITIVE_STATUSES.include?(e.status) ? close!(:skipped, e.code) : postpone!(e.code, retry_after: e.retry_after)
      end

      private

      def client = @client ||= Github::Client.new

      def decide(state)
        return close!(:skipped, "pull_request_not_open") unless state[:state] == "OPEN"
        return close!(:skipped, "pull_request_not_on_main") unless on_main?(state)

        case state[:mergeable]
        when "MERGEABLE" then close!(:clean, nil)
        when "CONFLICTING" then SendBack.call(check: @check, now: @now)
        else postpone!("mergeable_unknown")
        end
      end

      # The base is read from the same answer as the merge state (CYRA-614): a proposal retargeted to
      # another branch, or opened from a fork onto another repository, is not in conflict with this main.
      def on_main?(state)
        state[:base_ref].present? && state[:base_ref] == state[:base_default_branch] &&
          state[:base_repository].to_s.casecmp?(@check.repository_full_name)
      end

      # `attempts` counts the reads that gave no answer. A rate limit says when to come back: never earlier.
      def postpone!(code, retry_after: nil)
        attempts = @check.attempts + 1
        return give_up!(code, attempts) if attempts >= MAX_READS

        delay = [ self.class.delay_after(attempts), retry_after.to_i.seconds ].max
        write!(state: :pending, attempts:, next_check_at: @now + delay, last_error_code: code)
      end

      def give_up!(code, attempts)
        Rails.logger.warn("[agents.conflict_check] gave up after #{attempts} reads: " \
                          "#{@check.repository_full_name}##{@check.number} main=#{@check.main_sha.first(12)} " \
                          "check=#{@check.id} last=#{code}")
        close!(:gave_up, code, attempts:)
      end

      def close!(state, code, attempts: @check.attempts)
        write!(state:, attempts:, next_check_at: nil, last_error_code: code)
      end

      # Only the read that still finds the row as it left it writes; the other one leaves it alone.
      def write!(state:, attempts:, next_check_at:, last_error_code:)
        Agents::ConflictCheck.where(id: @check.id, state: :pending, attempts: @check.attempts)
                             .update_all(state: Agents::ConflictCheck.states.fetch(state.to_s), attempts:,
                                         last_checked_at: @now, next_check_at:, last_error_code:, updated_at: @now)
        Result.ok(@check.reload)
      end
    end
  end
end
