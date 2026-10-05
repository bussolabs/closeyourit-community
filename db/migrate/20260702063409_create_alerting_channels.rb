class CreateAlertingChannels < ActiveRecord::Migration[8.1]
  def change
    create_table :alerting_channels, id: :uuid do |t|
      t.timestamps

      t.references :organization, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :created_by, type: :uuid, foreign_key: { to_table: :accounts, on_delete: :nullify }

      t.string :name, null: false
      t.integer :kind, null: false, default: 0
      # webhook: { "url" => ..., "secret" => ... } · telegram: { "bot_token" => ..., "chat_id" => ... }
      t.jsonb :config, null: false, default: {}
      t.boolean :enabled, null: false, default: true

      t.index %i[organization_id name], unique: true
    end
  end
end
