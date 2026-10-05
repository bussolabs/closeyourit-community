class CreateSecretsVariables < ActiveRecord::Migration[8.1]
  def change
    create_table :secrets_variables, id: :uuid do |t|
      t.timestamps

      # Chi ha creato/aggiornato la variabile (nullify: la variabile sopravvive alla cancellazione account).
      t.references :created_by, type: :uuid,
                   foreign_key: { to_table: :accounts, on_delete: :nullify }, null: true

      # Tenancy denormalizzata (scoping/query per org, coerente con Ticketing::Event / Errors::Event).
      t.references :organization, type: :uuid, null: false, foreign_key: true
      # Radice di scoping: la variabile appartiene a un progetto (immutabile, attr_readonly sul model).
      t.references :project, type: :uuid, null: false, foreign_key: true
      # Dimensione ambiente: DEVE essere dichiarata dal progetto (vincolo subset sul model).
      t.references :environment, type: :uuid, null: false,
                   foreign_key: { to_table: :types_environments }

      # Nome della variabile: UPPER_SNAKE (^[A-Z_][A-Z0-9_]*$), vietato prefisso GITHUB_ (vincolo Actions).
      t.string :name, null: false
      # Valore cifrato at-rest via ActiveRecord::Encryption (encrypts :value, non-deterministico).
      # text: il ciphertext + metadata è più lungo del plaintext.
      t.text :value, null: false
      t.text :description

      # Una variabile per [progetto, ambiente, nome].
      t.index %i[project_id environment_id name], unique: true,
              name: "index_secrets_variables_on_project_env_name"
    end
  end
end
