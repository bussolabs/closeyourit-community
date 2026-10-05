# frozen_string_literal: true

# CYSK-29 — la telemetria d'uso: quali simboli (rotte come Controller#action, job, chiavi custom)
# vengono davvero eseguiti. Due tabelle, e la seconda è il vero dispositivo anti-falso-positivo:
# `usage_reporters` registra «questo progetto STA MANDANDO usage di tipo route da T» — senza, non
# si distingue «rotta mai chiamata» da «SDK non ancora deployato lì». Un simbolo morto non ha riga:
# la telemetria produce solo l'insieme positivo, il verdetto «inutilizzato» lo calcola lo scanner.
class CreateUsageTables < ActiveRecord::Migration[8.1]
  def change
    create_table :usage_symbols, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :project_id, null: false
      t.string :environment, null: false
      t.string :kind, null: false
      t.string :symbol, null: false
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at, null: false
      t.bigint :hits_count, null: false, default: 0
      t.string :last_release
      t.string :last_sdk_version
      t.timestamps

      t.index %i[project_id environment kind symbol], unique: true, name: "idx_usage_symbols_identity"
      t.index %i[project_id last_seen_at]
    end
    add_foreign_key :usage_symbols, :projects, on_delete: :cascade

    create_table :usage_reporters, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :project_id, null: false
      t.string :environment, null: false
      t.string :kind, null: false
      t.string :sdk_name, null: false
      t.string :sdk_version
      t.string :release
      t.datetime :first_reported_at, null: false
      t.datetime :last_reported_at, null: false
      t.boolean :truncated_last_window, null: false, default: false
      t.timestamps

      t.index %i[project_id environment kind sdk_name], unique: true, name: "idx_usage_reporters_identity"
    end
    add_foreign_key :usage_reporters, :projects, on_delete: :cascade
  end
end
