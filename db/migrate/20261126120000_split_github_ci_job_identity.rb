# frozen_string_literal: true

# CYRA-1164 — a CI job is known by its workflow and its own name, kept apart; each run keeps its branch.
# The tables are new and still empty, so the old combined name is dropped without carrying it over.
class SplitGithubCiJobIdentity < ActiveRecord::Migration[8.1]
  def change
    remove_index :github_ci_jobs, %i[repository_id name], unique: true
    remove_column :github_ci_jobs, :name, :string, null: false
    add_column :github_ci_jobs, :workflow_name, :string, null: false, default: ""
    add_column :github_ci_jobs, :job_name, :string, null: false # rubocop:disable Rails/NotNullColumn
    add_index :github_ci_jobs, %i[repository_id workflow_name job_name], unique: true

    add_column :github_ci_job_runs, :head_branch, :string
  end
end
