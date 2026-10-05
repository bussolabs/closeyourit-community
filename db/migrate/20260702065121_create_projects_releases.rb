class CreateProjectsReleases < ActiveRecord::Migration[8.1]
  def change
    create_table :projects_releases, id: :uuid do |t|
      t.timestamps

      t.references :project, type: :uuid, null: false, foreign_key: { on_delete: :cascade }

      t.string :version, null: false
      t.string :sha
      t.datetime :build_time
      t.datetime :first_event_at
      t.datetime :last_event_at
      t.integer :events_count, null: false, default: 0

      t.index %i[project_id version], unique: true
      t.index %i[project_id created_at]
    end
  end
end
