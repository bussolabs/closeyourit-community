class CreateTypesTicketPriorities < ActiveRecord::Migration[8.1]
  def change
    create_table :types_ticket_priorities, id: :uuid do |t|
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
  end
end
