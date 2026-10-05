# frozen_string_literal: true

# CYSK-26 — l'estratto di copertura che la CI pubblica dal branch di default: quali file sono stati
# percorsi dalle prove, quali rami non sono mai stati presi, e i metadati della run. Una sola riga
# per [progetto, branch] (upsert): lo storico non serve — la deriva la tiene la sweep, qui conta
# l'ultima fotografia leggibile senza rigirare la suite.
class CreateProjectsCoverageReports < ActiveRecord::Migration[8.1]
  def change
    create_table :projects_coverage_reports, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.uuid :project_id, null: false
      t.string :branch, null: false
      t.string :sha
      t.datetime :captured_at, null: false
      t.decimal :line_covered_percent, precision: 5, scale: 2
      t.decimal :branch_covered_percent, precision: 5, scale: 2
      t.integer :files_count, null: false, default: 0
      t.integer :never_loaded_count, null: false, default: 0
      t.jsonb :payload, null: false, default: {}
      t.timestamps

      t.index %i[project_id branch], unique: true
    end
    add_foreign_key :projects_coverage_reports, :projects, on_delete: :cascade
  end
end
