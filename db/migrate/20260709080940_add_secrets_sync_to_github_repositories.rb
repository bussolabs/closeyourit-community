class AddSecretsSyncToGithubRepositories < ActiveRecord::Migration[8.1]
  def change
    # Opt-in del push dei secret del vault verso i GitHub Environment secrets (distinto da sync_enabled,
    # che è la ricezione webhook in ingresso).
    add_column :github_repositories, :sync_secrets, :boolean, default: false, null: false
    # Nomi già sincronizzati per slot ({"production"=>["A","B"], "staging"=>[...]}): abilita il
    # delete-only-managed (cancella su GitHub solo ciò che il vault aveva messo, mai i secret manuali).
    add_column :github_repositories, :synced_secret_names, :jsonb, default: {}, null: false
  end
end
