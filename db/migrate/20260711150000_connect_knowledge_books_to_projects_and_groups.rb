# frozen_string_literal: true

class ConnectKnowledgeBooksToProjectsAndGroups < ActiveRecord::Migration[8.1]
  def up
    add_reference :knowledge_books, :organization, type: :uuid, foreign_key: true
    execute <<~SQL.squish
      UPDATE knowledge_books
      SET organization_id = projects.organization_id
      FROM projects
      WHERE knowledge_books.project_id = projects.id
    SQL
    change_column_null :knowledge_books, :organization_id, false

    create_table :connections_book_projects, id: :uuid do |t|
      t.timestamps

      t.references :book, type: :uuid, null: false, foreign_key: { to_table: :knowledge_books }
      t.references :project, type: :uuid, null: false, foreign_key: { to_table: :projects }

      t.index %i[book_id project_id], unique: true
    end

    create_table :connections_book_groups, id: :uuid do |t|
      t.timestamps

      t.references :book, type: :uuid, null: false, foreign_key: { to_table: :knowledge_books }
      t.references :group, type: :uuid, null: false, foreign_key: { to_table: :projects_groups }

      t.index %i[book_id group_id], unique: true
    end

    execute <<~SQL.squish
      INSERT INTO connections_book_projects (id, created_at, updated_at, book_id, project_id)
      SELECT gen_random_uuid(), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, id, project_id
      FROM knowledge_books
    SQL

    remove_reference :knowledge_books, :project, type: :uuid, foreign_key: true
  end

  def down
    add_reference :knowledge_books, :project, type: :uuid, foreign_key: true

    execute <<~SQL.squish
      UPDATE knowledge_books
      SET project_id = links.project_id
      FROM (
        SELECT DISTINCT ON (book_id) book_id, project_id
        FROM connections_book_projects
        ORDER BY book_id, created_at, id
      ) links
      WHERE knowledge_books.id = links.book_id
    SQL

    change_column_null :knowledge_books, :project_id, false
    drop_table :connections_book_groups
    drop_table :connections_book_projects
    remove_reference :knowledge_books, :organization, type: :uuid, foreign_key: true
  end
end
