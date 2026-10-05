class CreateAiRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :ai_requests, id: :uuid do |t|
      t.timestamps

      t.references :account, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :organization, type: :uuid, null: false, foreign_key: { on_delete: :cascade }

      t.string :kind, null: false
      t.integer :status, null: false, default: 0
      t.jsonb :args, null: false, default: {}
      t.jsonb :payload, null: false, default: {}
      t.string :error_code
      t.string :error_message

      t.index %i[account_id created_at]
    end
  end
end
