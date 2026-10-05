# Coworkers name their assistant Puck (docs/glossario-prodotto.md): the old "dot" naming goes away.
class RenameCoworkersDotsToPuckies < ActiveRecord::Migration[8.1]
  def change
    rename_table :coworkers_dots, :coworkers_puckies
    rename_column :coworkers_runs, :dot_id, :puck_id
  end
end
