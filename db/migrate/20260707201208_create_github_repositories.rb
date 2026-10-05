# frozen_string_literal: true

class CreateGithubRepositories < ActiveRecord::Migration[8.1]
  def change
    create_table :github_repositories, id: :uuid do |t|
      t.timestamps

      # Link repo↔progetto 1:1: un progetto ha al più un repo (unique su project_id) e un repo
      # ha al più un progetto (unique [installation_id, repo_id]).
      t.references :project, type: :uuid, null: false, foreign_key: true,
                   index: { unique: true }
      t.references :installation, type: :uuid, null: false,
                   foreign_key: { to_table: :github_installations }

      # Mapping stabilità→environment (le "regole" dal setting del progetto): il tag stabile lega la
      # release in production_environment, il pre-release in staging_environment.
      t.references :production_environment, type: :uuid, null: true,
                   foreign_key: { to_table: :types_environments }
      t.references :staging_environment, type: :uuid, null: true,
                   foreign_key: { to_table: :types_environments }

      t.bigint  :repo_id, null: false                       # id numerico del repo GitHub (stabile ai rename)
      t.string  :full_name, null: false                     # "owner/name"
      t.string  :default_branch, null: false, default: "main"
      t.boolean :sync_enabled, null: false, default: true   # ricezione/elaborazione eventi webhook
      t.boolean :tag_binding_enabled, null: false, default: true # abilita il binding tag→release live
      t.boolean :autoclose_on_merge, null: false, default: false # PR merged → status ticket done

      t.index [ :installation_id, :repo_id ], unique: true  # un repo ↔ al più un progetto (1:1 doppio senso)
    end
  end
end
