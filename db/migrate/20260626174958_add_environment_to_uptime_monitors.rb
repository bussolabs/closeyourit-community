# frozen_string_literal: true

class AddEnvironmentToUptimeMonitors < ActiveRecord::Migration[8.1]
  def change
    # 1 monitor per [progetto, environment]: l'environment è obbligatorio e dichiarato dal progetto.
    # on_delete: :restrict → non si elimina un environment con monitor (come per i token).
    add_reference :uptime_monitors, :environment, type: :uuid, null: false,
                  foreign_key: { to_table: :types_environments, on_delete: :restrict }
    add_index :uptime_monitors, %i[project_id environment_id], unique: true
  end
end
