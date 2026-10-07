module Coworkers
  # Every minute: start the scheduled tasks and the watch checks that are due (CYRA-1001, CYRA-1011).
  # A busy Puck keeps its slot and is retried next minute; missed slots collapse into one run. A team Puck's
  # schedule runs as whoever saved it and its checks as its creator, while they may still act (CYRA-1023).
  class TickJob < ApplicationJob
    queue_as :maintenance
    BATCH = 50

    def perform(at = Time.current)
      return unless Coworkers.enabled?

      due_schedules(at).each { |schedule| run_schedule(schedule, at) }
      due_watches(at).each { |puck| Coworkers.can_act?(puck.account, puck) ? Watch.check(puck, at: at) : puck.update_columns(watch_next_at: at + puck.watch_every_minutes.minutes) }
    end

    private

    def due_schedules(at) = Schedule.due(at).includes(:created_by, puck: %i[account organization]).order(:next_run_at).limit(BATCH)

    def due_watches(at)
      Puck.where.not(watch_every_minutes: nil).where("watch_next_at IS NULL OR watch_next_at <= ?", at)
          .includes(:account, :organization).order(Arel.sql("watch_next_at NULLS FIRST"), :id).limit(BATCH)
    end

    def run_schedule(schedule, at)
      puck = schedule.puck
      actor = puck.team? ? schedule.created_by : puck.account
      schedule.with_lock do
        next unless schedule.next_run_at <= at && !schedule.paused?
        # A team schedule whose author may no longer act pauses, with its next slot, in one write.
        next schedule.update!(paused: puck.team?, next_run_at: schedule.next_after(at)) unless Coworkers.can_act?(actor, puck)

        Start.call(puck: puck, kind: "task", input: schedule.input, schedule: schedule, slot_at: schedule.next_run_at, account: actor)
        schedule.advance!(at)
      end
    rescue Start::Busy, Start::OverBudget
      nil
    end
  end
end
