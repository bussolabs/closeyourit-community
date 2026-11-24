# frozen_string_literal: true

# CYRA-1231 — the nightly PruneJob deletes evaluations older than 30 days in batches of 1000. Without an
# index on created_at every batch read the whole table and sorted all expired rows by their UUID before
# keeping the first 1000. With this index, and the batch ordered by created_at, each batch reads only
# the oldest rows and stops.
#
# CONCURRENTLY (+ disable_ddl_transaction!) so evaluations keep being written while the index is built.
class AddCreatedAtIndexToAlertingEvaluations < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = "index_alerting_evaluations_on_created_at"

  def up
    # An interrupted CREATE INDEX CONCURRENTLY leaves an INVALID index with this name: dropping any
    # leftover first (concurrently, no-op when absent) makes the migration re-runnable.
    remove_index :alerting_evaluations, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
    add_index :alerting_evaluations, :created_at, name: INDEX_NAME, algorithm: :concurrently
  end

  def down
    remove_index :alerting_evaluations, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
  end
end
