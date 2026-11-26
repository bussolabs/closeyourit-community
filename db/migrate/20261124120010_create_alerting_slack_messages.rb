# frozen_string_literal: true

# CYRA-1156 — every alert posted by the Slack app: where the message lives, who took it, the mute,
# the ticket and whether it recovered. `version` grows on every change, `rendered_version` is the
# last one written to Slack: an older refresh is dropped.
class CreateAlertingSlackMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :alerting_slack_messages, id: :uuid do |t|
      t.references :organization, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :channel, type: :uuid, null: false,
                             foreign_key: { to_table: :alerting_channels, on_delete: :cascade }
      t.references :rule, type: :uuid, foreign_key: { to_table: :alerting_rules, on_delete: :nullify }
      t.references :project, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :event_type, null: false
      t.string :subject_type, null: false
      t.uuid :subject_id, null: false
      t.string :slack_channel, null: false
      t.string :slack_ts, null: false
      t.string :title, null: false
      t.text :body
      t.string :url
      t.integer :status, null: false, default: 0
      t.datetime :recovered_at
      t.references :claimed_by, type: :uuid, foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.datetime :claimed_at
      t.references :muted_by, type: :uuid, foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.datetime :muted_until
      t.references :ticket, type: :uuid, foreign_key: { to_table: :ticketing_tickets, on_delete: :nullify }
      t.references :ticket_opened_by, type: :uuid, foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.integer :version, null: false, default: 1
      t.integer :rendered_version, null: false, default: 1
      t.timestamps
    end
    add_index :alerting_slack_messages, %i[slack_channel slack_ts], unique: true
    add_index :alerting_slack_messages, %i[subject_type subject_id status], name: "idx_alerting_slack_messages_subject"
  end
end
