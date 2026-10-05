# frozen_string_literal: true

# AI provider chosen from the admin area instead of the environment, so a self-hosted install
# can connect its own provider or a CloseYourIt key without a redeploy (CYRA-916).
# A NULL provider keeps reading the environment: existing installs behave as before.
class AddAiProviderToSettingsGlobal < ActiveRecord::Migration[8.1]
  def change
    change_table :settings_global, bulk: true do |t|
      t.string :ai_provider
      t.string :ai_base_url
      t.text :ai_api_key
      t.string :ai_chat_model
      t.string :ai_embedding_model
      t.integer :ai_embedding_dimensions
      t.string :ai_transcription_model
      t.string :ai_rerank_base_url
      t.text :ai_rerank_api_key
      t.string :ai_rerank_model
    end
  end
end
