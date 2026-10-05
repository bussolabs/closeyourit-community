# One row per organization that does not simply follow the platform AI (CYRA-914 phase 2).
# A new table: nothing existing is rewritten, and an organization without a row keeps today's AI.
class CreateOrganizationAiSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :organization_ai_settings, id: :uuid do |t|
      t.timestamps
      t.references :organization, type: :uuid, null: false, foreign_key: true, index: { unique: true }
      t.string :mode, null: false, default: "platform"
      t.string :base_url
      t.text :api_key
      t.string :chat_model
      t.string :embedding_model
      t.string :transcription_model
      t.string :rerank_base_url
      t.text :rerank_api_key
      t.string :rerank_model
      t.bigint :monthly_token_cap
    end
  end
end
