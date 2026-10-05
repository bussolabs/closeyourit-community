class CreateConnectionsInvitations < ActiveRecord::Migration[8.1]
  def change
    create_table :connections_invitations, id: :uuid do |t|
      t.timestamps

      t.references :organization, type: :uuid, null: false, foreign_key: true
      t.references :invited_by, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts }

      t.string   :email,       null: false
      t.integer  :role,        null: false, default: 0
      t.datetime :accepted_at, null: true

      # Un solo invito pendente per email+organizzazione.
      t.index [ :organization_id, :email ], unique: true,
              name: "index_invitations_pending_per_org_email"
    end
  end
end
