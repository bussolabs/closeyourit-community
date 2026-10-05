# frozen_string_literal: true

class CreateDatasetsTrainings < ActiveRecord::Migration[8.1]
  def change
    # Artefatto PERSISTENTE di un training: il prompt ottimizzato + metriche. È anche il record di
    # stato del job (pending/running/done/failed) — non si riusa Ai::Request (effimero, per-account).
    create_table :datasets_trainings, id: :uuid do |t|
      t.timestamps

      t.references :dataset, type: :uuid, null: false,
                   foreign_key: { to_table: :datasets_datasets, on_delete: :cascade }
      t.references :created_by, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts, on_delete: :nullify }

      t.integer :status,        null: false, default: 0
      t.text    :system_prompt
      t.jsonb   :config,        null: false, default: {}   # few-shot ids, iterazioni, modello usato
      t.jsonb   :metrics,       null: false, default: {}   # accuratezza holdout, n. esempi
      t.string  :error_code
      t.string  :error_message

      t.index %i[dataset_id status]
    end
  end
end
