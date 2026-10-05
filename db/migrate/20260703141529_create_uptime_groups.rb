# frozen_string_literal: true

# Gruppo di monitor uptime: contenitore ORG-LEVEL (non per-progetto) che aggrega monitor anche di
# progetti diversi in una status page unica. Gemello di projects_groups, ma sui monitor uptime.
# Cancellazione: i monitor sopravvivono e diventano "senza gruppo" (group_id → nullify).
# `slug` = identificatore leggibile per la status page pubblica per-gruppo (/status/g/:org/:slug).
class CreateUptimeGroups < ActiveRecord::Migration[8.1]
  def change
    create_table :uptime_groups, id: :uuid do |t|
      t.timestamps

      t.references :created_by, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts }
      t.references :organization, type: :uuid, null: false, foreign_key: true

      t.string  :name,   null: false
      t.string  :color
      t.string  :icon
      t.string  :slug,   null: false
      t.text    :description
      t.boolean :public_status_enabled, null: false, default: false

      t.index [ :organization_id, :name ]
      t.index [ :organization_id, :slug ], unique: true
    end
  end
end
