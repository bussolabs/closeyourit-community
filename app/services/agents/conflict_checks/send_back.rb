# frozen_string_literal: true

module Agents
  module ConflictChecks
    # CYRA-1154 — the proposal no longer merges: the work goes back to the agent in conflict resolution
    # mode, once per proposal; a proposal that already had that round stops with the reason. One
    # transaction locks the workflow, then the row, and checks everything again: only the caller that
    # moves the row out of pending resets the work and writes the notice.
    #
    # GitHub is read before, outside: an HTTP call in here would hold the locks for a slow network.
    class SendBack < ApplicationService
      def initialize(check:, now: Time.current)
        @check = check
        @now = now
      end

      def call
        ApplicationRecord.transaction do
          workflow = @check.workflow
          workflow.lock!
          @check.lock!
          next unless @check.state_pending?

          skip = ConflictChecks.skip_reason(workflow, @check)
          next skip!(skip) if skip

          round_used = round_used?(workflow)
          next unless claim_row!(round_used ? "stopped" : "sent_back")

          absorb_other_pushes!
          Agents::Candidates::ConflictRework.call(workflow:, candidate: @check.delivery_candidate, now: @now,
                                                  round_used:, detail: "main #{@check.main_sha.first(12)}")
          next if round_used

          move_ticket!(workflow)
          record_notice!(workflow.ticket)
        end
        Result.ok(@check.reload)
      end

      private

      # The request covers a round asked and not delivered yet; the used mark outlives the delivery and is
      # written by every path that grants the round (first verification, six-hour recheck, the agent stopping
      # on a conflict, as after the staging release, and this check). Further rounds are a person's call.
      def round_used?(workflow)
        workflow.conflict_resolution_requested_at.present? || workflow.conflict_resolution_used_at.present?
      end

      # The step out of pending is a conditional write: the second guard after the unique index.
      def claim_row!(state)
        Agents::ConflictCheck.where(id: @check.id, state: :pending)
                             .update_all(state: Agents::ConflictCheck.states.fetch(state), handled_at: @now,
                                         last_checked_at: @now, next_check_at: nil, last_error_code: nil,
                                         updated_at: @now)
                             .positive?
      end

      # Other pushes of main still pending for the same delivery, out of order or a few seconds apart, would
      # only ask GitHub the same question: their titles join this row, oldest push first, and they close.
      def absorb_other_pushes!
        others = Agents::ConflictCheck.state_pending.where(delivery_candidate_id: @check.delivery_candidate_id)
                                      .where.not(id: @check.id)
        rows = (others.to_a + [ @check ]).sort_by(&:created_at)
        return if rows.one?

        titles = rows.flat_map { |row| Array(row.main_titles) }.uniq.first(Agents::ConflictCheck::TITLES_LIMIT)
        @check.update_columns(main_titles: titles, main_commits_count: rows.sum(&:main_commits_count))
        others.update_all(state: Agents::ConflictCheck.states.fetch("skipped"), last_error_code: "superseded",
                          last_checked_at: @now, next_check_at: nil, updated_at: @now)
      end

      # Under the lock the work had already moved on (another change sent it back, or a person acted).
      def skip!(code)
        @check.update!(state: :skipped, last_checked_at: @now, next_check_at: nil, last_error_code: code)
      end

      # Like a rejected review, the ticket goes back to the first working status that is not a review.
      # ChangeStatus broadcasts only after the commit; a status it refuses leaves the rework in place.
      def move_ticket!(workflow)
        ticket = workflow.ticket
        status = workflow.organization.ticket_statuses.active.where(review_gate: false).category_in_progress.ordered.first
        return if status.nil? || status.id == ticket.status_id

        result = Ticketing::ChangeStatus.call(organization: workflow.organization, ticket:, status_id: status.id,
                                              channel: :workflow,
                                              dependency_mode: Ticketing::DependencyGuard.mode_for("autopilot"))
        Rails.logger.info("[agents.conflict_check] status not moved: #{result.error.code} ticket=#{ticket.id}") if result.err?
      end

      def record_notice!(ticket)
        Ticketing::RecordActivity.call(
          ticket:, action: "pull_request_conflict",
          data: { number: @check.number, main_sha: @check.main_sha.first(12), changes: @check.main_commits_count },
          actor_name: I18n.t("member.tickets.activity.system.github")
        )
      end
    end
  end
end
