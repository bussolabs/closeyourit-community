# Tokens each organization spent on AI chat in a month, and the platform's monthly cap (CYRA-914).
# A new table and an empty column on the one-row settings table: nothing large is rewritten.
class CreateAiUsageMonths < ActiveRecord::Migration[8.1]
  def change
    create_table :ai_usage_months, id: :uuid do |t|
      t.timestamps
      t.references :organization, type: :uuid, null: false, foreign_key: true, index: false
      t.date :month, null: false
      t.bigint :tokens, null: false, default: 0
      t.index %i[organization_id month], unique: true
    end

    add_column :settings_global, :ai_org_monthly_token_cap, :bigint
  end
end
