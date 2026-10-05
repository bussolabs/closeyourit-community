# frozen_string_literal: true

class CreateDatasetsCells < ActiveRecord::Migration[8.1]
  def change
    # Cella FOTO: una per (riga, colonna kind=photo). L'immagine è un blob ActiveStorage
    # (has_one_attached :image). Le celle scalari vivono in datasets_rows.cell_values.
    create_table :datasets_cells, id: :uuid do |t|
      t.timestamps

      t.references :row, type: :uuid, null: false,
                   foreign_key: { to_table: :datasets_rows, on_delete: :cascade }
      t.references :column, type: :uuid, null: false,
                   foreign_key: { to_table: :datasets_columns, on_delete: :cascade }

      t.index %i[row_id column_id], unique: true
    end
  end
end
