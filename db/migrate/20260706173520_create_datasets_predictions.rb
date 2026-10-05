# frozen_string_literal: true

class CreateDatasetsPredictions < ActiveRecord::Migration[8.1]
  def change
    # Inferenza su dati nuovi: applica il prompt di un training a una riga di input
    # (datasets_rows con purpose=prediction) e conserva il result predetto.
    create_table :datasets_predictions, id: :uuid do |t|
      t.timestamps

      t.references :dataset, type: :uuid, null: false,
                   foreign_key: { to_table: :datasets_datasets, on_delete: :cascade }
      t.references :training, type: :uuid, null: true,
                   foreign_key: { to_table: :datasets_trainings, on_delete: :nullify }
      t.references :created_by, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.references :input_row, type: :uuid, null: false,
                   foreign_key: { to_table: :datasets_rows, on_delete: :cascade }

      t.integer :status,           null: false, default: 0
      # Valori predetti per ogni colonna target (keyed per target code). Multi-attributo.
      t.jsonb   :predicted_values, null: false, default: {}
      t.string  :error_code
      t.string  :error_message

      t.index %i[dataset_id created_at]
    end
  end
end
