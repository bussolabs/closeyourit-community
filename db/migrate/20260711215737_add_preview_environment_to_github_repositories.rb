class AddPreviewEnvironmentToGithubRepositories < ActiveRecord::Migration[8.1]
  # Idempotente: lo schema di main porta già `preview_environment_id` (dump orfano di 9009a2b2,
  # generato mentre il DB dev condiviso aveva questa migration applicata). Su un DB nato da
  # schema:load la colonna esiste già → guardiamo prima di aggiungere/indicizzare/collegare.
  def up
    add_column :github_repositories, :preview_environment_id, :uuid, null: true, if_not_exists: true
    add_index :github_repositories, :preview_environment_id, if_not_exists: true
    unless foreign_key_exists?(:github_repositories, :types_environments, column: :preview_environment_id)
      add_foreign_key :github_repositories, :types_environments, column: :preview_environment_id
    end
  end

  def down
    remove_foreign_key :github_repositories, column: :preview_environment_id, if_exists: true
    remove_column :github_repositories, :preview_environment_id, if_exists: true
  end
end
