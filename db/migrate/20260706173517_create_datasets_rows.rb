# frozen_string_literal: true

class CreateDatasetsRows < ActiveRecord::Migration[8.1]
  def change
    create_table :datasets_rows, id: :uuid do |t|
      t.timestamps

      t.references :dataset, type: :uuid, null: false,
                   foreign_key: { to_table: :datasets_datasets, on_delete: :cascade }

      # Valori delle celle SCALARI keyed per column code (result incluso). Le celle foto stanno in
      # datasets_cells (ActiveStorage). Nome non-`values` per evitare clash con AR (idioma Logs::Entry).
      t.jsonb   :cell_values, null: false, default: {}
      t.integer :position,    null: false, default: 0
      # sample = riga etichettata di training · prediction = input di inferenza.
      t.integer :purpose,     null: false, default: 0

      t.index %i[dataset_id purpose]
    end
  end
end
