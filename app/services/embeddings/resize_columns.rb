# frozen_string_literal: true

module Embeddings
  # Changes the size of every embedding column when the admin picks an embedding model with a
  # different size (CYRA-916). Old vectors cannot be converted, so they are cleared together with
  # their version: the daily backfill jobs, enqueued at once by ResizeColumnsJob, embed everything
  # again with the new model. One transaction: PostgreSQL DDL rolls back as a whole.
  class ResizeColumns < ApplicationService
    TABLES = %w[errors_groups helpdesk_requests ideas_ideas knowledge_pages ticketing_tickets].freeze

    def initialize(dimensions:)
      @dimensions = Integer(dimensions)
    end

    def call
      unless @dimensions.between?(1, Ai::Configuration::MAX_EMBEDDING_DIMENSIONS)
        return Result.err(AppError.new("Embedding size out of range: #{@dimensions}",
                                       code: "R422-AI-001", status: :unprocessable_content))
      end

      tables = TABLES.reject { |table| current_size(table) == @dimensions }
      ActiveRecord::Base.transaction { tables.each { |table| resize(table) } }
      # Prepared statements cached before the change still expect the old column type. Rails
      # refreshes them by itself outside a transaction; this connection is cleared right away.
      connection.clear_cache! if tables.any?
      Result.ok(tables)
    end

    private

    def connection = ActiveRecord::Base.connection

    def current_size(table)
      connection.select_value(<<~SQL.squish).to_i
        SELECT atttypmod FROM pg_attribute
        WHERE attrelid = #{connection.quote(table)}::regclass AND attname = 'embedding'
      SQL
    end

    def resize(table)
      index = "index_#{table}_on_embedding"
      connection.execute("DROP INDEX IF EXISTS #{connection.quote_column_name(index)}")
      quoted = connection.quote_table_name(table)
      connection.execute("UPDATE #{quoted} SET embedding = NULL, embedding_version = NULL, embedding_checksum = NULL")
      connection.execute("ALTER TABLE #{quoted} ALTER COLUMN embedding TYPE vector(#{connection.quote(@dimensions)}) USING NULL")
      connection.add_index(table, :embedding, name: index, using: :hnsw, opclass: :vector_cosine_ops)
    end
  end
end
