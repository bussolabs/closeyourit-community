# frozen_string_literal: true

# Wikitech (CYRA-1127): external tech knowledge of an organization, never about its own projects.
# Notes are the plain text a member sends; entries are the cards (one per project) built from them;
# sources link a card to every note that talks about it.
class CreateWikitechTables < ActiveRecord::Migration[8.1]
  def change
    create_table :wikitech_notes, id: :uuid do |t|
      t.timestamps
      t.references :organization, type: :uuid, null: false, index: false,
                                  foreign_key: { to_table: :organizations, on_delete: :cascade }
      t.references :created_by, type: :uuid, foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.text :body, null: false
      t.string :source_label
      t.string :source_url
      t.datetime :source_published_at
      t.text :links, array: true, null: false, default: []
      t.string :checksum, null: false
      t.integer :status, null: false, default: 0, comment: "0 pending · 1 processed · 2 discarded"
      t.datetime :processed_at
      t.string :last_error
    end
    add_index :wikitech_notes, %i[organization_id checksum], unique: true
    add_index :wikitech_notes, %i[organization_id status]

    create_table :wikitech_entries, id: :uuid do |t|
      t.timestamps
      t.references :organization, type: :uuid, null: false, index: false,
                                  foreign_key: { to_table: :organizations, on_delete: :cascade }
      t.string :name, null: false
      t.string :name_key, null: false
      t.string :repo_url
      t.text :summary
      t.text :facts, array: true, null: false, default: []
      t.text :categories, array: true, null: false, default: []
      t.text :links, array: true, null: false, default: []
      t.integer :verification, null: false, default: 0, comment: "0 unconfirmed · 1 verified"
      t.jsonb :repo_meta
      t.datetime :repo_checked_at
      t.integer :sources_count, null: false, default: 0
      t.datetime :embedded_at
      t.string :embedding_checksum
      t.string :embedding_version
      t.column :embedding, :vector, limit: 1024
    end
    add_index :wikitech_entries, %i[organization_id repo_url], unique: true, where: "repo_url IS NOT NULL"
    add_index :wikitech_entries, %i[organization_id name_key]
    add_index :wikitech_entries, :categories, using: :gin
    add_index :wikitech_entries, :embedding, using: :hnsw, opclass: :vector_cosine_ops
    add_index :wikitech_entries, :embedding_version

    create_table :wikitech_sources, id: :uuid do |t|
      t.timestamps
      t.references :entry, type: :uuid, null: false, index: false,
                           foreign_key: { to_table: :wikitech_entries, on_delete: :cascade }
      t.references :note, type: :uuid, null: false,
                          foreign_key: { to_table: :wikitech_notes, on_delete: :cascade }
      t.text :quote
    end
    add_index :wikitech_sources, %i[entry_id note_id], unique: true
  end
end
