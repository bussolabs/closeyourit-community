# frozen_string_literal: true

class CreateWebsiteAccessRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :website_access_requests, id: :uuid do |t|
      t.string :name, null: false
      t.string :email, null: false
      t.string :team, null: false
      t.text :context, null: false
      t.string :locale, null: false, default: "en"
      t.string :status, null: false, default: "pending"
      t.timestamps
    end
    add_index :website_access_requests, :email
    add_index :website_access_requests, :status
  end
end
