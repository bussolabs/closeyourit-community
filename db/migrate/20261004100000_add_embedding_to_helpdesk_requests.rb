# frozen_string_literal: true

# Help desk requests that say the same thing are shown together (CYRA-943). Same four columns as the
# other embedded tables. All nullable, no backfill: without AI they stay empty and nothing groups.
class AddEmbeddingToHelpdeskRequests < ActiveRecord::Migration[8.1]
  def change
    change_table :helpdesk_requests, bulk: true do |t|
      t.datetime :embedded_at
      t.string   :embedding_checksum
      t.string   :embedding_version
      t.column   :embedding, :vector, limit: 1024
    end
    add_index :helpdesk_requests, :embedding, using: :hnsw, opclass: :vector_cosine_ops
    add_index :helpdesk_requests, :embedding_version

    change_column_comment :helpdesk_requests, :status,
                          from: "0 received · 1 discarded · 2 converted · 3 linked",
                          to: "0 received · 1 discarded · 2 converted · 3 linked · 4 answered"
  end
end
