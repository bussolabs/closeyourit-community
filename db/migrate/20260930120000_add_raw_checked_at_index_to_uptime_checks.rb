# frozen_string_literal: true

# The hourly rollup and the raw prune filter raw checks by time across all monitors; every other
# index starts with monitor_id, so each run read the whole table (CYRA-892). CONCURRENTLY keeps
# check writes flowing while the index builds.
class AddRawCheckedAtIndexToUptimeChecks < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  INDEX_NAME = "idx_uptime_checks_raw_checked_at"

  def up
    # An interrupted CONCURRENTLY build leaves an INVALID index with this name: drop it first.
    remove_index :uptime_checks, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
    add_index :uptime_checks, :checked_at, name: INDEX_NAME, where: "granularity = 0", algorithm: :concurrently
  end

  def down
    remove_index :uptime_checks, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
  end
end
