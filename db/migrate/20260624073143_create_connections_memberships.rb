class CreateConnectionsMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :connections_memberships, id: :uuid do |t|
      t.timestamps

      t.references :account,      type: :uuid, null: false, foreign_key: true
      t.references :organization, type: :uuid, null: false, foreign_key: true
      t.integer    :role,         null: false, default: 0

      t.index [ :account_id, :organization_id ], unique: true,
              name: "index_memberships_on_account_and_organization"
      t.index :organization_id, unique: true, where: "role = 2",
              name: "index_one_owner_per_organization"
    end
  end
end
