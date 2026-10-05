# frozen_string_literal: true

# CYRA-907 — an action the assistant proposes; nothing is written until the user confirms it.
class CreateAssistantProposals < ActiveRecord::Migration[8.1]
  def change
    create_table :assistant_proposals, id: :uuid do |t|
      t.references :message, type: :uuid, null: false,
                             foreign_key: { to_table: :assistant_messages, on_delete: :cascade }
      t.references :organization, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :account, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.integer :kind, null: false
      t.integer :status, null: false, default: 0
      t.jsonb :payload, null: false, default: {}
      t.string :result_type
      t.uuid :result_id
      t.string :error_code
      t.datetime :confirmed_at
      t.timestamps
    end
  end
end
