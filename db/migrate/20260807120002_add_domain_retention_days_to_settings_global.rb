# frozen_string_literal: true

# Estende la gerarchia di retention god → org → progetto (già log/analytics) a errori, performance,
# server e disponibilità (CYRA-159). Additiva: 4 colonne integer nullable + backfill della riga
# singleton esistente ai default per-dominio (il livello di sistema dev'essere sempre valorizzato).
class AddDomainRetentionDaysToSettingsGlobal < ActiveRecord::Migration[8.1]
  def up
    change_table :settings_global, bulk: true do |t|
      t.integer :errors_retention_days
      t.integer :performance_retention_days
      t.integer :servers_retention_days
      t.integer :uptime_retention_days
    end

    execute <<~SQL.squish
      UPDATE settings_global
      SET errors_retention_days = 30, performance_retention_days = 30,
          servers_retention_days = 30, uptime_retention_days = 730
    SQL
  end

  def down
    change_table :settings_global, bulk: true do |t|
      t.remove :errors_retention_days, :performance_retention_days,
               :servers_retention_days, :uptime_retention_days
    end
  end
end
