class CreateAnalyticsGoals < ActiveRecord::Migration[8.1]
  def change
    create_table :analytics_goals, id: :uuid do |t|
      t.timestamps

      t.references :project, null: false, foreign_key: { on_delete: :cascade }, type: :uuid

      t.integer :kind, null: false, default: 0
      t.string :event_name
      t.string :path_pattern
      t.string :display_name, null: false

      # Un goal custom-event è unico per (progetto, nome evento); un goal pageview-path è unico per
      # (progetto, pattern). Indici parziali per non collidere tra i due tipi.
      t.index %i[project_id event_name], unique: true, where: "kind = 1", name: "idx_analytics_goals_event"
      t.index %i[project_id path_pattern], unique: true, where: "kind = 0", name: "idx_analytics_goals_path"
    end
  end
end
