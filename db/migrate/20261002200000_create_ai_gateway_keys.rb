# frozen_string_literal: true

# CloseYourIt AI keys in preview (CYRA-920): given by hand to self-hosted installs, each with a
# monthly token limit. Only the SHA-256 of the key is stored; usage is counted per key and month,
# never the text of the requests.
class CreateAiGatewayKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :ai_gateway_keys, id: :uuid do |t|
      t.string :name, null: false
      t.string :contact_email
      t.string :token_digest, null: false
      t.string :token_prefix, null: false
      t.bigint :monthly_token_limit, null: false
      t.datetime :suspended_at
      t.datetime :revoked_at
      t.datetime :last_used_at
      t.references :created_by, type: :uuid, foreign_key: { to_table: :accounts }
      t.timestamps
    end
    add_index :ai_gateway_keys, :token_digest, unique: true

    create_table :ai_gateway_usages, id: :uuid do |t|
      t.references :key, type: :uuid, null: false, foreign_key: { to_table: :ai_gateway_keys }
      t.date :month, null: false
      t.bigint :tokens_input, null: false, default: 0
      t.bigint :tokens_output, null: false, default: 0
      t.integer :requests, null: false, default: 0
      t.timestamps
    end
    add_index :ai_gateway_usages, %i[key_id month], unique: true
  end
end
