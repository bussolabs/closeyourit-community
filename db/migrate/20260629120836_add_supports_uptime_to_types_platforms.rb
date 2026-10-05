# Capability "uptime" della piattaforma: distingue le piattaforme web/server (monitorabili via
# HTTP-ping) dalle app native (ios/android). I progetti senza piattaforma uptime-capable nascondono
# la sezione uptime. Default false (opt-in dalla CRUD); backfill della default "web" a true.
class AddSupportsUptimeToTypesPlatforms < ActiveRecord::Migration[8.1]
  def up
    add_column :types_platforms, :supports_uptime, :boolean, null: false, default: false
    execute "UPDATE types_platforms SET supports_uptime = TRUE WHERE code = 'web'"
  end

  def down
    remove_column :types_platforms, :supports_uptime
  end
end
