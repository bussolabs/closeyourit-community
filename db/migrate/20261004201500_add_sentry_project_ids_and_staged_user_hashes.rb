# frozen_string_literal: true

# projects is read by every ingest request and errors_ingest_payloads receives them: each step takes its
# lock on its own, with a short lock_timeout, and the checks are validated last under a lock that leaves
# reads and writes alone (CYRA-914 D8). The resulting schema is unchanged.
class AddSentryProjectIdsAndStagedUserHashes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  LOCK_TIMEOUT = "5s"

  CHECKS = {
    projects: [ "projects_sentry_id_safe_integer", "sentry_project_id > 0 AND sentry_project_id <= 9007199254740991" ],
    errors_ingest_payloads: [ "errors_ingest_payloads_user_hash_format", "user_hash IS NULL OR user_hash ~ '^[0-9a-f]{16}$'" ]
  }.freeze

  def up
    execute "SET lock_timeout = '#{LOCK_TIMEOUT}'"
    # A separate sequence preserves UUID identity while satisfying numeric Sentry DSNs.
    add_column :projects, :sentry_project_id, :bigserial, null: false, if_not_exists: true
    add_column :errors_ingest_payloads, :user_hash, :string, limit: 16, if_not_exists: true
    CHECKS.each do |table, (name, expression)|
      add_check_constraint table, expression, name: name, validate: false unless check_constraint_exists?(table, name: name)
    end
    execute "RESET lock_timeout"

    add_index :projects, :sentry_project_id, unique: true, algorithm: :concurrently, if_not_exists: true
    CHECKS.each { |table, (name, _)| validate_check_constraint table, name: name }
  end

  def down
    CHECKS.each { |table, (name, _)| remove_check_constraint table, name: name, if_exists: true }
    remove_index :projects, :sentry_project_id, if_exists: true
    remove_column :errors_ingest_payloads, :user_hash, if_exists: true
    remove_column :projects, :sentry_project_id, if_exists: true
  end
end
