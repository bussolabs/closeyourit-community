# frozen_string_literal: true

class CreateAgentsSkillReleases < ActiveRecord::Migration[8.0]
  def change
    create_table :agents_skill_releases, id: :uuid do |t|
      t.string :version, null: false
      t.string :url, null: false
      t.string :sha256, null: false
      t.string :git_sha
      t.datetime :published_at, null: false
      t.datetime :withdrawn_at
      t.uuid :withdrawn_by_id
      t.timestamps
    end
    add_index :agents_skill_releases, :version, unique: true

    create_table :agents_skill_release_pins, id: :uuid do |t|
      t.references :organization, type: :uuid, null: false, foreign_key: { to_table: :organizations },
                                  index: { unique: true }
      t.references :skill_release, type: :uuid, null: false, foreign_key: { to_table: :agents_skill_releases }
      t.uuid :pinned_by_id
      t.timestamps
    end
  end
end
