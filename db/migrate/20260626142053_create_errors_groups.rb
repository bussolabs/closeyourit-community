# frozen_string_literal: true

class CreateErrorsGroups < ActiveRecord::Migration[8.1]
  def change
    create_table :errors_groups, id: :uuid do |t|
      t.timestamps

      # Cancellando il progetto, i suoi gruppi d'errore spariscono.
      t.references :project, type: :uuid, null: false,
                   foreign_key: { to_table: :projects, on_delete: :cascade }

      t.string  :fingerprint, null: false   # chiave di deduplica (Errors::Fingerprint)
      t.string  :title,       null: false
      t.string  :culprit                     # punto di colpa (es. "App::Foo#bar")
      t.integer :level,  null: false, default: 3   # enum: debug/info/warning/error/fatal
      t.integer :status, null: false, default: 0   # enum: unresolved/resolved/ignored

      t.bigint   :events_count, null: false, default: 0
      t.bigint   :users_count,  null: false, default: 0
      t.datetime :first_seen_at
      t.datetime :last_seen_at
      t.string   :release

      # Link al ticket promosso (il ticket sopravvive alla cancellazione del gruppo).
      t.references :ticket, type: :uuid, null: true,
                   foreign_key: { to_table: :ticketing_tickets, on_delete: :nullify }

      t.index %i[project_id fingerprint], unique: true
      t.index %i[project_id status last_seen_at]
    end
  end
end
