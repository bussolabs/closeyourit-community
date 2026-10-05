# frozen_string_literal: true

# Help desk requests written by the visitors of a project's site (CYRA-940). A request is not a
# ticket: the team reads it and decides. Messages are a list from the start, so replies fit later.
class CreateHelpdeskRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :helpdesk_enabled, :boolean, null: false, default: false

    create_table :helpdesk_requests, id: :uuid do |t|
      t.references :project, type: :uuid, null: false, foreign_key: true
      t.integer :status, null: false, default: 0, comment: "0 received · 1 discarded"
      t.string :summary, null: false
      t.text :email, comment: "Encrypted. The visitor's address: personal data, erased on request or by retention"
      t.datetime :email_erased_at
      t.text :page_url
      t.string :browser
      t.string :os
      t.string :device_type
      t.string :session_id, comment: "The SDK visit id, shared with errors and replays of the same visit"
      t.datetime :discarded_at
      t.references :discarded_by, type: :uuid, foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.timestamps
    end
    add_index :helpdesk_requests, %i[project_id status created_at]

    create_table :helpdesk_messages, id: :uuid do |t|
      t.references :request, type: :uuid, null: false, foreign_key: { to_table: :helpdesk_requests, on_delete: :cascade }
      t.integer :direction, null: false, default: 0, comment: "0 inbound (visitor) · 1 outbound (team)"
      t.text :body, null: false
      t.references :author, type: :uuid, foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.timestamps
    end
  end
end
