# frozen_string_literal: true

# CYRA-1164 — the outcome of every finished CI job GitHub reports, grouped by job name per repository.
class CreateGithubCiJobs < ActiveRecord::Migration[8.1]
  def change
    create_table :github_ci_jobs, id: :uuid do |t|
      t.references :repository, type: :uuid, null: false, index: false,
                                foreign_key: { to_table: :github_repositories, on_delete: :cascade }
      t.references :ticket, type: :uuid, foreign_key: { to_table: :ticketing_tickets, on_delete: :nullify }
      t.string :name, null: false
      t.timestamps
    end
    add_index :github_ci_jobs, %i[repository_id name], unique: true

    create_table :github_ci_job_runs, id: :uuid do |t|
      t.references :ci_job, type: :uuid, null: false, index: false,
                            foreign_key: { to_table: :github_ci_jobs, on_delete: :cascade }
      t.bigint :github_job_id, null: false
      t.bigint :run_id, null: false
      t.integer :run_attempt, null: false, default: 1
      t.string :head_sha, null: false
      t.string :conclusion, null: false
      t.datetime :queued_at
      t.datetime :started_at
      t.datetime :completed_at, null: false
      t.timestamps
    end
    add_index :github_ci_job_runs, :github_job_id, unique: true
    add_index :github_ci_job_runs, %i[ci_job_id completed_at]
    add_index :github_ci_job_runs, :completed_at
  end
end
