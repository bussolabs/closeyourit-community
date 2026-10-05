# frozen_string_literal: true

# Join server ↔ environment di progetto: dichiara su quali host gira ogni environment
# di un progetto uptime-capable (N host per coppia [project, environment]).
class CreateConnectionsEnvironmentHosts < ActiveRecord::Migration[8.1]
  def change
    create_table :connections_environment_hosts, id: :uuid do |t|
      t.timestamps

      t.references :project, type: :uuid, null: false,
                   foreign_key: { to_table: :projects, on_delete: :cascade }
      t.references :environment, type: :uuid, null: false,
                   foreign_key: { to_table: :types_environments, on_delete: :restrict }
      t.references :host, type: :uuid, null: false,
                   foreign_key: { to_table: :servers_hosts, on_delete: :cascade }
      t.references :created_by, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts, on_delete: :nullify }

      t.index %i[project_id environment_id host_id], unique: true,
              name: "index_connections_environment_hosts_unique"
    end
  end
end
