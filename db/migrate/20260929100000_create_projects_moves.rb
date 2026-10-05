# frozen_string_literal: true

# CYRA-879 — one row per move of a project or group to another organization.
class CreateProjectsMoves < ActiveRecord::Migration[8.1]
  def change
    create_table :projects_moves, id: :uuid do |t|
      t.string :subject_type, null: false
      t.uuid :subject_id, null: false
      t.references :source_organization, type: :uuid, null: false, foreign_key: { to_table: :organizations, on_delete: :cascade }
      t.references :destination_organization, type: :uuid, null: false, foreign_key: { to_table: :organizations, on_delete: :cascade }
      t.references :requested_by, type: :uuid, foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.integer :status, null: false, default: 0
      t.jsonb :plan, null: false, default: {}
      t.string :error_message
      t.datetime :finished_at
      t.timestamps
    end
    add_index :projects_moves, %i[subject_type subject_id], unique: true, where: "status IN (0, 1)",
                                                            name: "index_projects_moves_one_active_per_subject"
  end
end
