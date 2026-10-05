# frozen_string_literal: true

class CreateGithubInstallations < ActiveRecord::Migration[8.1]
  def change
    create_table :github_installations, id: :uuid do |t|
      t.timestamps

      # Un'installazione GitHub App per organizzazione (1:1): l'org connette l'App una volta.
      t.references :organization, type: :uuid, null: false, foreign_key: true,
                   index: { unique: true }

      t.bigint :installation_id, null: false # id numerico dell'installazione (GitHub) — mint dei token
      t.string :account_login, null: false   # login dell'org/utente GitHub proprietario dell'installazione

      t.index :installation_id, unique: true
    end
  end
end
