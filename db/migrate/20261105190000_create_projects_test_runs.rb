# frozen_string_literal: true

# CYRA-1165 — the test results a CI sends: one row per run (version, commit, branch, totals), one per
# test in that run, a stable identity per test so its history accumulates, and the failures a person
# marked as already known, with the ticket that will fix them and an expiry.
class CreateProjectsTestRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :projects_test_runs, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :project_id, null: false
      t.uuid :release_id
      t.string :version
      t.string :sha, null: false
      t.string :branch
      t.datetime :ran_at, null: false
      t.integer :tests_count, null: false, default: 0
      t.integer :passed_count, null: false, default: 0
      t.integer :failed_count, null: false, default: 0
      t.integer :known_failed_count, null: false, default: 0
      t.integer :skipped_count, null: false, default: 0
      t.bigint :duration_ms
      t.timestamps

      t.index %i[project_id ran_at]
      t.index %i[project_id sha]
      t.index :release_id
    end
    add_foreign_key :projects_test_runs, :projects, on_delete: :cascade
    add_foreign_key :projects_test_runs, :projects_releases, column: :release_id, on_delete: :nullify

    create_table :projects_test_cases, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :project_id, null: false
      t.string :identity_digest, null: false
      t.string :file, null: false, default: ""
      t.text :name, null: false
      t.string :last_status
      t.datetime :last_run_at
      t.datetime :flaky_at
      t.string :flaky_sha
      t.timestamps

      t.index %i[project_id identity_digest], unique: true
      t.index %i[project_id last_run_at]
      t.index %i[project_id flaky_at]
    end
    add_foreign_key :projects_test_cases, :projects, on_delete: :cascade

    create_table :projects_test_results, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :test_run_id, null: false
      t.uuid :test_case_id, null: false
      t.string :status, null: false
      t.boolean :known_failure, null: false, default: false
      t.integer :duration_ms
      t.text :message
      t.timestamps

      t.index %i[test_run_id test_case_id], unique: true
      t.index :test_case_id
    end
    add_foreign_key :projects_test_results, :projects_test_runs, column: :test_run_id, on_delete: :cascade
    add_foreign_key :projects_test_results, :projects_test_cases, column: :test_case_id, on_delete: :cascade

    create_table :projects_known_failures, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :project_id, null: false
      t.uuid :test_case_id, null: false
      t.uuid :ticket_id
      t.uuid :marked_by_id
      t.date :expires_on, null: false
      t.timestamps

      t.index :test_case_id, unique: true
      t.index %i[project_id expires_on]
      t.index :ticket_id
      t.index :marked_by_id
    end
    add_foreign_key :projects_known_failures, :projects, on_delete: :cascade
    add_foreign_key :projects_known_failures, :projects_test_cases, column: :test_case_id, on_delete: :cascade
    add_foreign_key :projects_known_failures, :ticketing_tickets, column: :ticket_id, on_delete: :nullify
    add_foreign_key :projects_known_failures, :accounts, column: :marked_by_id, on_delete: :nullify
  end
end
