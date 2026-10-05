# frozen_string_literal: true

class CreateDatasetsColumns < ActiveRecord::Migration[8.1]
  def change
    create_table :datasets_columns, id: :uuid do |t|
      t.timestamps

      t.references :dataset, type: :uuid, null: false,
                   foreign_key: { to_table: :datasets_datasets, on_delete: :cascade }

      t.string  :code,     null: false
      t.string  :label,    null: false
      t.integer :position, null: false, default: 0
      t.integer :kind,     null: false, default: 0   # text/number/category/boolean/photo
      t.integer :role,     null: false, default: 0   # input (0, dato fornito) / target (1, da predire)
      t.boolean :required, null: false, default: false
      # Spazio dei valori quando kind=category (anche per i target categoriali): è l'output space del prompt.
      t.jsonb   :options,  null: false, default: []

      t.index %i[dataset_id code], unique: true
      t.index %i[dataset_id position]
      # Più target ammessi per dataset (multi-attributo): niente vincolo "un solo target".
      t.index %i[dataset_id role]
    end
  end
end
