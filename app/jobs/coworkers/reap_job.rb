module Coworkers
  class ReapJob < ApplicationJob
    queue_as :maintenance

    def perform
      return unless Coworkers.enabled? && Coworkers.remote?
      # Revoked owners still need their abandoned executions finalized.
      changed = []
      Run.active.includes(:puck).find_each do |run|
        run.with_lock do
          expired = run.status == "queued" ? run.created_at < 5.minutes.ago : run.lease_expires_at && run.lease_expires_at <= Time.current
          next unless run.active? && (run.stop_requested? || expired)
          run.update!(status: run.stop_requested? ? "stopped" : "interrupted", ended_at: Time.current, error_code: expired ? "runtime_interrupted" : nil)
          changed << run
        end
      end
      # The bubble shows the run's proposed actions: load them once for every finalized run.
      ActiveRecord::Associations::Preloader.new(records: changed, associations: [ :action_proposals, { child_runs: :puck } ]).call
      Run.load_media(changed.select { |run| run.kind == "task" })
      changed.each(&:publish)
    end
  end
end
