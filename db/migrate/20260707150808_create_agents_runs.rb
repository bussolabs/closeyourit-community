class CreateAgentsRuns < ActiveRecord::Migration[8.1]
  def change
    # Esecuzione di un agente riportata da closeyourit-automator (mirror crons_check_ins + output).
    # Multi-target → una run per (agente × progetto-target). Ciclo start→finish: creata `running`,
    # aggiornata a success/fail alla chiusura. `output` = stdout/JSON troncato del comando.
    create_table :agents_runs, id: :uuid do |t|
      t.timestamps

      t.references :agent, type: :uuid, null: false,
                   foreign_key: { to_table: :agents_agents, on_delete: :cascade }
      t.references :project, type: :uuid, null: true,
                   foreign_key: { to_table: :projects, on_delete: :nullify }

      t.integer  :status,      null: false, default: 0   # 0=running 1=success 2=fail
      t.datetime :started_at,  null: false
      t.datetime :finished_at
      t.integer  :duration_ms
      t.integer  :exit_code
      t.text     :output
      t.text     :error

      t.index %i[agent_id started_at]
    end
  end
end
