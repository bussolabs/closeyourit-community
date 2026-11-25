# frozen_string_literal: true

# CYRA-1163 — the preview of a link written in a ticket description: title, short description, site
# and image, read in the background and kept until `expires_at` (7 days when it worked, 1 hour when it
# did not). One row per organization and address: a page read for one tenant is never shown to another.
class CreateTicketingLinkPreviews < ActiveRecord::Migration[8.1]
  def change
    create_table :ticketing_link_previews, id: :uuid do |t|
      t.references :organization, type: :uuid, null: false, index: false,
                                  foreign_key: { on_delete: :cascade }
      t.string :url, null: false
      t.string :status, null: false
      t.string :title
      t.string :description
      t.string :site_name
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :ticketing_link_previews, %i[organization_id url], unique: true
    add_index :ticketing_link_previews, :expires_at
  end
end
