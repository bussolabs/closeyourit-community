# frozen_string_literal: true

class CreateDatasetsDatasets < ActiveRecord::Migration[8.1]
  def change
    create_table :datasets_datasets, id: :uuid do |t|
      t.timestamps

      t.references :project, type: :uuid, null: false,
                   foreign_key: { to_table: :projects, on_delete: :cascade }
      t.references :created_by, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts, on_delete: :nullify }

      t.string :name,        null: false
      t.text   :description
      t.integer :status,     null: false, default: 0

      t.index %i[project_id status]
    end
  end
end
