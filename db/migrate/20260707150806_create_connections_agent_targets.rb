class CreateConnectionsAgentTargets < ActiveRecord::Migration[8.1]
  def change
    # Join multi-target Agents::Agent ↔ (Projects::Project | Projects::Group). Un agente è assegnato
    # a N progetti e/o N gruppi; esattamente uno tra project/group per riga (validato sul model).
    # Assegnare a un gruppo copre i suoi progetti (RBAC covers? lo risolve già). NULL è distinto in PG
    # → gli indici unici semplici bastano (più righe con project_id NULL non collidono).
    create_table :connections_agent_targets, id: :uuid do |t|
      t.timestamps

      t.references :agent, type: :uuid, null: false,
                   foreign_key: { to_table: :agents_agents, on_delete: :cascade }
      t.references :project, type: :uuid, null: true,
                   foreign_key: { to_table: :projects, on_delete: :cascade }
      t.references :group, type: :uuid, null: true,
                   foreign_key: { to_table: :projects_groups, on_delete: :cascade }

      t.index %i[agent_id project_id], unique: true
      t.index %i[agent_id group_id], unique: true
    end
  end
end
