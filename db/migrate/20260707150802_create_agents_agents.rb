class CreateAgentsAgents < ActiveRecord::Migration[8.1]
  def change
    # Agente = definizione di un'azione schedulata (mirror 1:1 dello schema playbook di
    # closeyourit-automator). Org-scoped: gli agenti non appartengono a un progetto ma vengono
    # ASSEGNATI a progetti/gruppi (join connections_agent_targets). Il `cwd` NON vive qui — è
    # machine-specific e sta nella mappa host locale dell'automator. `run` = prompt o "/skill".
    create_table :agents_agents, id: :uuid do |t|
      t.timestamps

      t.references :organization, type: :uuid, null: false,
                   foreign_key: { on_delete: :cascade }
      t.references :created_by, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts, on_delete: :nullify }

      t.string   :slug,            null: false
      t.string   :name,            null: false
      t.text     :description
      t.integer  :kind,            null: false, default: 0   # 0=claude 1=shell
      t.text     :run,             null: false
      t.string   :schedule,        null: false               # cron 5-campi UTC o shorthand ("every 15m")
      t.integer  :timeout_seconds, null: false, default: 300
      t.string   :permission_mode                            # solo kind claude
      t.jsonb    :allowed_tools,   null: false, default: []
      t.string   :model
      t.boolean  :enabled,         null: false, default: true
      t.boolean  :catch_up,        null: false, default: false
      t.jsonb    :on_failure                                 # { "run" => "..." }
      # Denormalizzati dall'ultima run (per la lista senza join).
      t.datetime :last_run_at
      t.integer  :last_run_status                            # mirror enum Agents::Run.status

      t.index %i[organization_id slug], unique: true
      t.index %i[organization_id enabled]
    end
  end
end
