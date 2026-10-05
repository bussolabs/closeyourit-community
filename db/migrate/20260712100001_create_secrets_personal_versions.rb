class CreateSecretsPersonalVersions < ActiveRecord::Migration[8.1]
  def change
    create_table :secrets_personal_versions, id: :uuid do |t|
      t.timestamps

      # La variabile di cui è snapshot; alla cancellazione della variabile lo storico va con lei.
      t.references :variable, type: :uuid, null: false,
                   foreign_key: { to_table: :secrets_personal_variables, on_delete: :cascade }

      # Numero monotòno per variabile (v1, v2, …). Unico per [variabile, numero].
      t.integer :number, null: false
      # Valore snapshottato, cifrato at-rest (encrypts :value sul model, come Secrets::Personal::Variable).
      t.text :value, null: false

      t.index %i[variable_id number], unique: true
    end
  end
end
