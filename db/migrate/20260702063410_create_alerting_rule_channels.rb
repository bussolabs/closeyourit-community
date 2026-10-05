class CreateAlertingRuleChannels < ActiveRecord::Migration[8.1]
  def change
    create_table :alerting_rule_channels, id: :uuid do |t|
      t.timestamps

      t.references :rule, type: :uuid, null: false, foreign_key: { to_table: :alerting_rules, on_delete: :cascade }
      t.references :channel, type: :uuid, null: false, foreign_key: { to_table: :alerting_channels, on_delete: :cascade }

      t.index %i[rule_id channel_id], unique: true
    end
  end
end
