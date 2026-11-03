# frozen_string_literal: true

# CYRA-1158 — events carry a few short properties, projects declare their events, and a custom-event
# goal may count only one property value. Existing goals keep a null filter and stay unique.
class AddEventPropertiesToAnalytics < ActiveRecord::Migration[8.1]
  def change
    add_column :analytics_pageviews, :properties, :jsonb, default: {}, null: false

    create_table :analytics_event_definitions, id: :uuid do |t|
      t.references :project, type: :uuid, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :name, null: false
      t.string :property_names, array: true, default: [], null: false
      t.timestamps
    end
    add_index :analytics_event_definitions, %i[project_id name], unique: true

    add_column :analytics_goals, :property_name, :string
    add_column :analytics_goals, :property_value, :string
    remove_index :analytics_goals, %i[project_id event_name], name: "idx_analytics_goals_event",
                                                              unique: true, where: "(kind = 1)"
    add_index :analytics_goals, %i[project_id event_name property_name property_value],
              name: "idx_analytics_goals_event", unique: true, where: "(kind = 1)", nulls_not_distinct: true
  end
end
