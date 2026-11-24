# frozen_string_literal: true

module Agents
  module Workflows
    # CYRA-1327 — what happens when a piece of work runs out of attempts. Point 3 of the 2026-11-19
    # decision: it starts over on another engine ONCE, and if the attempts run out again it is set
    # aside — the ticket goes back to the backlog with a note, and no request reaches a person.
    #
    # Before this, every exhausted budget called a person: on 2026-11-19 the decision queue held 228
    # requests and nothing moved. The second run is not a retry of the same reader: the same engine on
    # the same ticket fails the same way, so the work is handed to the other one.
    #
    # Which engine that was lives on the NEW run (`budget_restart_engine`), and that column is also the
    # counter — written means "this is the second run". It cannot live on the old one: starting over
    # destroys it (Restart, CYRA-1070), and a counter there would die with it.
    #
    # Stops a person owns never pass through here: a safety stop (an agent tried to skip the gates), a
    # release a person is holding and the wait for production are decisions, not an exhausted budget.
    class ExhaustedBudget < ApplicationService
      PERSON_ONLY_KINDS = [ SafetyStop::KIND, HoldProduction::KIND, RequestProductionApproval::KIND ].freeze

      # The reasons that mean "the budget is finished", wherever they are written: the attempts cap on
      # a phase, the plan revisions and the supporter's retries.
      EXHAUSTION_REASONS = %w[retries_exhausted revisions_exhausted].freeze

      # Settled after the commit, never in place: see Agents::ExhaustedBudgetJob for why.
      #
      # The state it was decided on travels with it. Between the decision and the job a person can
      # press "retry" on the stop, approve the plan the supporter could not, or cancel the run — and
      # without this the job would destroy a run that had just gone back to work, with a machine on
      # it. Same rule as a supporter's verdict, which is pinned to the stop it read (CYRA-1197).
      def self.settle_later(workflow)
        workflow_id = workflow.id
        digest = state_digest(workflow)
        ActiveRecord.after_all_transactions_commit do
          Agents::ExhaustedBudgetJob.perform_later(workflow_id, digest)
        end
      end

      # Everything that would make the decision stale: the stop (and its kind), the plan approval, the
      # end of the run, and which plan version is waiting — a plan sent back for changes is a run that
      # moved. Deliberately NOT the attempts: a late report on a lost attempt does not change the
      # decision, and refusing it there would leave the budget unsettled.
      def self.state_digest(workflow)
        latest = workflow.plans.reorder(version: :desc).first
        Digest::SHA256.hexdigest(JSON.generate([
          workflow.blocked_at&.to_i, workflow.blocked_kind, workflow.approved_at&.to_i,
          workflow.cancelled_at&.to_i, workflow.completed_at&.to_i,
          latest&.id, latest&.change_request.present?
        ]))
      end

      # The supporter wanted one more round and the budget says no: that is an exhausted budget, not a
      # question for a person. Any OTHER reason on the list — a reserved topic, a suspected bypass, a
      # risk above the line, a concluded ticket — keeps the hand-over to a person as it is. Which
      # reasons carry nothing of their own is the caller's knowledge: it strips them before asking.
      def self.settle_later_if_only_the_budget(workflow:, reasons:)
        return false if (reasons & EXHAUSTION_REASONS).empty?
        return false if (reasons - EXHAUSTION_REASONS).any?

        settle_later(workflow)
        true
      end

      # CYRA-1357 — the agent stopped itself and the supporter did not send it back: settled like an
      # exhausted budget instead of waiting for a person. A reason only a person owns keeps the hand-over.
      PERSON_OWNED_REASONS = %w[reserved_topic bypass_suspected ticket_concluded].freeze

      def self.settle_later_if_the_agent_gave_up(workflow:, reasons:)
        return false unless workflow.blocked_kind == "agent_blocked"
        return false if reasons.empty? || (reasons & PERSON_OWNED_REASONS).any?

        settle_later(workflow)
        true
      end

      # `digest:` is the state the settlement was decided on (see .settle_later); nil skips the check,
      # for a caller that settles what it is reading right now.
      def initialize(workflow:, digest: nil)
        @workflow = workflow
        @ticket = workflow.ticket
        @digest = digest
      end

      # Result.ok(:restarted | :set_aside), or Result.ok(nil) when this stop is not ours to settle.
      #
      # The whole thing is one transaction: half of a set-aside — a closed run with no note and
      # nothing holding the ticket — would look exactly like a ticket ready to be picked up again,
      # and the `terminal?` check above would refuse to finish the job on the next try.
      def call
        outcome = nil
        ApplicationRecord.transaction do
          # TICKET first, then the run: the same order every other path takes (Attempts::Deliver
          # #lock_scope!, Cancel). Taken the other way round, this job and a late delivery on the same
          # ticket each hold what the other waits for — and PostgreSQL kills one of them. It would be
          # this one: ApplicationJob only retries TransientFailure, so a deadlock here would leave the
          # budget unsettled and the stop sitting in the queue with nobody able to say why.
          @ticket.lock!
          @workflow.lock!
          next if stale?

          outcome = @workflow.budget_restart_engine.present? ? set_aside : restart
        end
        outcome || Result.ok(nil)
      end

      private

      # Read again under the lock: a run that is over, a stop only a person lifts, work already out on
      # its way to release, or any move since the decision (a person's retry, an approval, a cancel)
      # leaves everything where it is.
      def stale?
        return true if @workflow.terminal? || PERSON_ONLY_KINDS.include?(@workflow.blocked_kind)
        return true if already_releasing?

        @digest.present? && @digest != self.class.state_digest(@workflow)
      end

      # An approved delivery is past the point where starting over means anything: the code is written
      # and a person said yes to it, so planning it again from scratch would throw that away, and
      # setting it aside would send a ticket back to the backlog whose code is already on the main
      # line. Those attempts ran out on a release, and a release is looked at, not redone. The
      # structure says the same: from here the run owns its release number, which must outlive even a
      # cancel (CYRA-1031) and whose foreign key refuses to let the run be destroyed.
      def already_releasing?
        @workflow.autopilot_approved_at?
      end

      def restart
        engine = next_engine
        phase = @workflow.blocked_phase
        result = Restart.call(workflow: @workflow, actor: nil, by_server: true, engine: engine)
        return result if result.err?

        Ticketing::RecordActivity.call(ticket: @ticket, action: "workflow_restarted_other_engine",
                                       actor_name: system_actor, data: { engine: engine, phase: phase })
        Result.ok(:restarted)
      end

      def set_aside
        result = Cancel.call(workflow: @workflow, actor: nil, by_server: true, reason: cancellation_reason)
        return result if result.err?

        Ticketing::RecordActivity.call(ticket: @ticket, action: "workflow_set_aside", actor_name: system_actor,
                                       data: { phase: @workflow.blocked_phase })
        hold_the_ticket!
        leave_a_note!
        Result.ok(:set_aside)
      end

      # The engine of the second run: the other one from the engine that just failed, read from the last
      # attempt. It doubles as the counter, so it always gets a value — with a single engine installed
      # the work starts over on that one, once, instead of starting over for ever.
      def next_engine
        failed = @workflow.attempts.order(:created_at).last&.runtime
        (Council::ENGINES - [ failed ]).first || Council::ENGINES.first
      end

      # An audit line, not the sentence a person reads: one language, stable shape.
      def cancellation_reason
        "exhausted_budget: #{@workflow.blocked_phase.presence || "the work"} ran out of attempts twice"
      end

      # The ticket is back in the backlog and must not be picked up on its own. Written like the
      # supporter's own decision (Ticketing::AutoDecideAgentEligibility): the DECISION column, the
      # reason a person reads, and the source left on `automatic` — so editing the ticket runs the
      # assessment again and may open it, while nothing automatic opens it meanwhile.
      def hold_the_ticket!
        from = @ticket.agent_eligibility
        ApplicationRecord.transaction do
          @ticket.update!(agent_eligibility: :blocked, agent_eligibility_reason: note("eligibility_reason"),
                          agent_eligibility_decided_at: Time.current, agent_eligibility_decided_by: nil)
          record_hold(from) unless from == @ticket.agent_eligibility
        end
      end

      def record_hold(from)
        Ticketing::RecordActivity.call(ticket: @ticket, action: "agent_eligibility_overridden",
                                       actor_name: system_actor,
                                       data: { agent_eligibility: { from: from, to: @ticket.agent_eligibility } })
      end

      # The note, as a fixed line: a comment has a hard length cap and the audit reason does not. A
      # comment must have an author, and the machine that worked the ticket last is the honest one;
      # without one (a host registered before machines had an identity) the note on the ticket card
      # still stands.
      def leave_a_note!
        author = @workflow.attempts.order(:created_at).last&.service_account
        return if author.nil?

        @ticket.comments.create!(body: note("service_line"), author: author, kind: :service)
      end

      # The language of whoever opened the ticket: a person reads this, not a machine.
      def note(key)
        I18n.with_locale(@ticket.reporter&.effective_locale || I18n.default_locale) do
          I18n.t("agents.exhausted_budget.#{key}")
        end
      end

      def system_actor = I18n.t("member.tickets.activity.system.autopilot")
    end
  end
end
