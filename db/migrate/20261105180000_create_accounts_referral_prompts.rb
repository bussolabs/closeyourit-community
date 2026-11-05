# frozen_string_literal: true

# CYRA-1162 — one row per person: tickets they closed, the next threshold, how many times the
# referral prompt was shown and whether they declined it for good.
class CreateAccountsReferralPrompts < ActiveRecord::Migration[8.1]
  def change
    create_table :accounts_referral_prompts, id: :uuid do |t|
      t.references :account, type: :uuid, null: false, index: { unique: true },
                             foreign_key: { on_delete: :cascade }
      t.integer :closed_tickets_count, null: false, default: 0
      t.integer :next_threshold, null: false, default: 10
      t.integer :shown_count, null: false, default: 0
      t.datetime :last_shown_at
      t.datetime :postponed_at
      t.datetime :declined_at
      t.timestamps
    end
  end
end
