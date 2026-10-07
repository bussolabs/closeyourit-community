# Puckies answer where they were asked: web, Telegram, Slack or the apps (CYRA-1018, CYRA-1019, CYRA-1022).
class AddChannelsToCoworkers < ActiveRecord::Migration[8.1]
  def change
    add_column :coworkers_runs, :channel, :string, null: false, default: "web"
    add_column :coworkers_runs, :channel_ref, :jsonb, null: false, default: {}
    add_check_constraint :coworkers_runs, "channel IN ('web', 'telegram', 'slack', 'app')", name: "coworkers_runs_channel_valid"

    create_table :coworkers_slack_links, id: :uuid do |t|
      t.references :account, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :organization, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :puck, type: :uuid, foreign_key: { to_table: :coworkers_puckies, on_delete: :nullify }
      t.string :slack_team_id, null: false
      t.string :slack_user_id, null: false
      t.timestamps
    end
    add_index :coworkers_slack_links, %i[slack_team_id slack_user_id], unique: true
  end
end
