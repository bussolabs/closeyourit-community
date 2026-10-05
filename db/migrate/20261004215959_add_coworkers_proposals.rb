class AddCoworkersProposals < ActiveRecord::Migration[8.1]
  def change
    add_column :coworkers_runs, :proposed_task, :jsonb, default: {}, null: false
    add_column :coworkers_runs, :proposal_superseded, :boolean, default: false, null: false
    add_reference :coworkers_runs, :proposal_run, type: :uuid, index: { unique: true }, foreign_key: { to_table: :coworkers_runs }
  end
end
