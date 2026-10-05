class AddWorkerLeaseToCoworkersRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :coworkers_runs, :worker_lease_id, :uuid
    add_column :coworkers_runs, :lease_expires_at, :datetime
    add_column :coworkers_runs, :runtime_deadline_at, :datetime
    add_column :coworkers_runs, :worker_sequence, :integer, default: 0, null: false
    add_column :coworkers_runs, :runtime_state, :jsonb, default: {}, null: false
    add_index :coworkers_runs, :lease_expires_at
  end
end
