# frozen_string_literal: true

# CYRA-1159 — the day each organization took each of its five first steps, plus the day the list was
# closed. Additive only: a new table and two new columns, no row rewritten. The organizations already
# there take the column default `true` (preexisting) when it is added; the default then turns to
# `false` for the ones born after. Their steps are rebuilt by the next, data-only migration.
class CreateOrganizationFirstSteps < ActiveRecord::Migration[8.1]
  def change
    create_table :organization_first_steps, id: :uuid do |t|
      t.references :organization, type: :uuid, null: false, index: false,
                                  foreign_key: { on_delete: :cascade }
      t.string :step, null: false
      t.datetime :reached_at, null: false
      t.datetime :created_at, null: false
    end
    add_index :organization_first_steps, %i[organization_id step], unique: true

    add_column :organizations, :first_steps_dismissed_at, :datetime
    add_column :organizations, :first_steps_preexisting, :boolean, null: false, default: true
    change_column_default :organizations, :first_steps_preexisting, from: true, to: false
  end
end
