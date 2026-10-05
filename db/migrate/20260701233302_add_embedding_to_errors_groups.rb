class AddEmbeddingToErrorsGroups < ActiveRecord::Migration[8.1]
  def change
    change_table :errors_groups, bulk: true do |t|
      t.datetime :embedded_at
      t.string   :embedding_checksum
      t.column   :embedding, :vector, limit: 1024
    end

    add_index :errors_groups, :embedding, using: :hnsw, opclass: :vector_cosine_ops
  end
end
