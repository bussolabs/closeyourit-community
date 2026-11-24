# frozen_string_literal: true

# CYRA-1231 — every minute ScheduleJob looks for unknown evaluations to retry, restricted to windows that
# ended in the last Evaluate::RETRY_WINDOW. No index covered that filter, so each run read the whole
# evaluation history. The existing (dispatch_state, retry_at) index does not help either: retry_at stays
# set on unknown rows after their retry window has expired, so a range on retry_at keeps growing with the
# history. A partial index on window_end_ns over unknown rows lets the lookup start from the last five
# minutes only.
#
# CONCURRENTLY (+ disable_ddl_transaction!) so evaluations keep being written while the index is built.
class AddUnknownWindowIndexToAlertingEvaluations < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = "index_alerting_evaluations_unknown_by_window_end"

  def up
    # An interrupted CREATE INDEX CONCURRENTLY leaves an INVALID index with this name: dropping any
    # leftover first (concurrently, no-op when absent) makes the migration re-runnable.
    remove_index :alerting_evaluations, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
    add_index :alerting_evaluations, :window_end_ns, where: "status = 'unknown'",
              name: INDEX_NAME, algorithm: :concurrently
  end

  def down
    remove_index :alerting_evaluations, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
  end
end
