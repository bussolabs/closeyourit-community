# frozen_string_literal: true

# OpenCode reviews through OpenRouter (CYAU-228): the organization lends one OpenRouter key to its machines,
# encrypted at rest and read only by certified hosts, and chooses the model on the Automator page.
class CreateAgentsOpenrouterCredentials < ActiveRecord::Migration[8.1]
  def change
    create_table :agents_openrouter_credentials, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.timestamps

      t.references :organization, type: :uuid, null: false, index: { unique: true },
                                  foreign_key: { on_delete: :cascade }
      t.references :set_by, type: :uuid, foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.text :token, null: false
    end

    add_column :agents_automator_settings, :opencode_model, :string
  end
end
