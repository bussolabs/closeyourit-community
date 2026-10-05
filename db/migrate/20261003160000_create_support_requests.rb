# frozen_string_literal: true

# Support requests sent from the footer (CYRA-935): the message plus the page and browser details
# that help reproduce the problem. Listed in Valhalla, where a god marks them handled.
class CreateSupportRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :support_requests, id: :uuid do |t|
      t.references :account, type: :uuid, null: false, foreign_key: true
      t.references :organization, type: :uuid, foreign_key: true
      t.text :body, null: false
      t.jsonb :context, null: false, default: {}
      t.datetime :handled_at
      t.references :handled_by, type: :uuid, foreign_key: { to_table: :accounts }
      t.timestamps
    end
    add_index :support_requests, %i[handled_at created_at]
  end
end
