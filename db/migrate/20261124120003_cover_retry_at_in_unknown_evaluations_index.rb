# frozen_string_literal: true

# Keep the recent-window range first and test due retries inside the index (CYRA-1231).
class CoverRetryAtInUnknownEvaluationsIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  OLD_INDEX = "index_alerting_evaluations_unknown_by_window_end"
  NEW_INDEX = "index_alerting_evaluations_unknown_by_window_and_retry"

  def up
    # Rebuild any invalid index left by an interrupted concurrent creation (CYRA-1231).
    remove_index :alerting_evaluations, name: NEW_INDEX, algorithm: :concurrently, if_exists: true
    add_index :alerting_evaluations, [ :window_end_ns, :retry_at ],
      where: "status = 'unknown'", name: NEW_INDEX, algorithm: :concurrently
    remove_index :alerting_evaluations, name: OLD_INDEX, algorithm: :concurrently, if_exists: true
  end

  def down
    remove_index :alerting_evaluations, name: OLD_INDEX, algorithm: :concurrently, if_exists: true
    add_index :alerting_evaluations, :window_end_ns,
      where: "status = 'unknown'", name: OLD_INDEX, algorithm: :concurrently
    remove_index :alerting_evaluations, name: NEW_INDEX, algorithm: :concurrently, if_exists: true
  end
end
