# frozen_string_literal: true

# The Claude credential an organization lends to its automator machines (CYAU-224).
# One per organization, encrypted at rest, written from the app and read only by certified hosts.
class CreateAgentsClaudeCredentials < ActiveRecord::Migration[8.1]
  def change
    create_table :agents_claude_credentials, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.timestamps

      t.references :organization, type: :uuid, null: false, index: { unique: true },
                                  foreign_key: { on_delete: :cascade }
      t.references :set_by, type: :uuid, foreign_key: { to_table: :accounts, on_delete: :nullify }
      # "api_key" or "oauth_token", derived from the token prefix.
      t.string :kind, null: false
      t.text :token, null: false
    end
  end
end
