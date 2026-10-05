# frozen_string_literal: true

class CreatePlatformsAndJoins < ActiveRecord::Migration[8.1]
  def change
    create_table :types_platforms, id: :uuid do |t|
      t.timestamps
      t.references :created_by, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts }
      t.references :organization, type: :uuid, null: false, foreign_key: true

      t.string  :code,     null: false
      t.string  :label,    null: false
      t.string  :color,    null: false
      t.integer :position, null: false, default: 0
      t.boolean :active,   null: false, default: true

      t.index [ :organization_id, :code ], unique: true
      t.index [ :organization_id, :active, :position ]
    end

    create_table :connections_project_platforms, id: :uuid do |t|
      t.timestamps
      t.references :project, type: :uuid, null: false, foreign_key: true
      t.references :platform, type: :uuid, null: false,
                   foreign_key: { to_table: :types_platforms }

      t.index [ :project_id, :platform_id ], unique: true
    end

    create_table :connections_ticket_platforms, id: :uuid do |t|
      t.timestamps
      t.references :ticket, type: :uuid, null: false,
                   foreign_key: { to_table: :ticketing_tickets }
      t.references :platform, type: :uuid, null: false,
                   foreign_key: { to_table: :types_platforms }

      t.index [ :ticket_id, :platform_id ], unique: true
    end
  end
end
