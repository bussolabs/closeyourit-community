module Coworkers
  class ReapJob < ApplicationJob
    queue_as :maintenance

    def perform
      return unless Coworkers.enabled? && Coworkers.remote?
      # Revoked owners still need their abandoned executions finalized.
      Run.active.includes(:puck).find_each do |run|
        changed = false
        run.with_lock do
          expired = run.status == "queued" ? run.created_at < 5.minutes.ago : run.lease_expires_at && run.lease_expires_at <= Time.current
          next unless run.active? && (run.stop_requested? || expired)
          run.update!(status: run.stop_requested? ? "stopped" : "interrupted", ended_at: Time.current, error_code: expired ? "runtime_interrupted" : nil)
          changed = true
        end
        run.publish if changed
      end
    end
  end
end
