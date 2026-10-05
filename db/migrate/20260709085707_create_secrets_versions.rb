class CreateSecretsVersions < ActiveRecord::Migration[8.1]
  def change
    create_table :secrets_versions, id: :uuid do |t|
      t.timestamps

      # Chi ha prodotto questa versione (nullify: la versione sopravvive alla cancellazione account).
      t.references :created_by, type: :uuid,
                   foreign_key: { to_table: :accounts, on_delete: :nullify }, null: true
      # La variabile di cui è snapshot; alla cancellazione della variabile lo storico va con lei.
      t.references :secret_variable, type: :uuid, null: false,
                   foreign_key: { to_table: :secrets_variables, on_delete: :cascade }

      # Numero monotòno per variabile (v1, v2, …). Unico per [variabile, numero].
      t.integer :number, null: false
      # Valore snapshottato, cifrato at-rest (encrypts :value sul model, come Secrets::Variable).
      t.text :value, null: false

      t.index %i[secret_variable_id number], unique: true
    end
  end
end
