# frozen_string_literal: true

class CreateGithubWebhookDeliveries < ActiveRecord::Migration[8.1]
  def change
    create_table :github_webhook_deliveries, id: :uuid do |t|
      t.string :delivery_id
      t.string :body_digest, null: false
      t.string :event, null: false
      t.text :body
      t.datetime :enqueued_at
      t.datetime :completed_at
      t.timestamps
    end
    add_index :github_webhook_deliveries, :delivery_id, unique: true
    add_index :github_webhook_deliveries, :body_digest, unique: true
    add_index :github_webhook_deliveries, :enqueued_at, where: "completed_at IS NULL"
  end
end
