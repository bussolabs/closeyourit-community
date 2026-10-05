# frozen_string_literal: true

# Da "pagina di UN progetto" (belongs_to project_id) a N:N su progetti + gruppi, ammettendo pagine
# "generali" org-wide (zero-scope). Stessa trasformazione già fatta per Knowledge::Book
# (20260711150000_connect_knowledge_books_to_projects_and_groups), qui con due divergenze:
# le pagine possono restare senza alcuno scope (org-wide) e portano tag liberi filtrabili.
class ConnectKnowledgePagesToProjectsAndGroups < ActiveRecord::Migration[8.1]
  def up
    # 1. Organization denormalizzata = fonte d'org primaria. Le pagine org-wide non hanno un progetto
    #    da cui derivarla, quindi l'org vive sulla riga (come knowledge_books/knowledge_versions).
    add_reference :knowledge_pages, :organization, type: :uuid, foreign_key: true
    execute <<~SQL.squish
      UPDATE knowledge_pages
      SET organization_id = projects.organization_id
      FROM projects
      WHERE knowledge_pages.project_id = projects.id
    SQL
    change_column_null :knowledge_pages, :organization_id, false

    # 2. Tag liberi (text[] + GIN), pattern Projects::Document#tags — filtro via overlap &&.
    add_column :knowledge_pages, :tags, :text, array: true, null: false, default: []
    add_index :knowledge_pages, :tags, using: :gin

    # 3-4. Join N:N (progetti diretti + gruppi), pattern connections_book_projects/book_groups.
    create_table :connections_page_projects, id: :uuid do |t|
      t.timestamps

      t.references :page, type: :uuid, null: false, foreign_key: { to_table: :knowledge_pages }
      t.references :project, type: :uuid, null: false, foreign_key: { to_table: :projects }

      t.index %i[page_id project_id], unique: true
    end

    create_table :connections_page_groups, id: :uuid do |t|
      t.timestamps

      t.references :page, type: :uuid, null: false, foreign_key: { to_table: :knowledge_pages }
      t.references :group, type: :uuid, null: false, foreign_key: { to_table: :projects_groups }

      t.index %i[page_id group_id], unique: true
    end

    # 5. Backfill: ogni pagina resta collegata al suo progetto attuale.
    execute <<~SQL.squish
      INSERT INTO connections_page_projects (id, created_at, updated_at, page_id, project_id)
      SELECT gen_random_uuid(), CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, id, project_id
      FROM knowledge_pages
    SQL

    # 6. Pre-check collisioni: l'identità di pubblicazione passa da [project_id, key] a
    #    [organization_id, key]. Se nello stesso org esistono già due pagine con la stessa key in
    #    progetti diversi (finora lecito), il nuovo indice unico fallirebbe: fermarsi con un report
    #    (vanno risolte a mano prima del deploy) invece di piantare un CREATE UNIQUE INDEX opaco.
    collisions = select_all(<<~SQL.squish).to_a
      SELECT organization_id, publication_key, COUNT(*) AS n
      FROM knowledge_pages
      WHERE publication_key IS NOT NULL
      GROUP BY organization_id, publication_key
      HAVING COUNT(*) > 1
    SQL
    if collisions.any?
      report = collisions.map { |r| "  org=#{r['organization_id']} key=#{r['publication_key']} (#{r['n']} pagine)" }.join("\n")
      raise "publication_key duplicati nello stesso org — risolvere prima del rollout:\n#{report}"
    end

    # 7. Identità di pubblicazione org-scoped. STESSO nome indice: è hard-coded in
    #    Knowledge::Pages::Publish (PUBLICATION_IDENTITY_INDEX) per il recovery del race.
    remove_index :knowledge_pages, name: "index_knowledge_pages_publication_identity"
    add_index :knowledge_pages, %i[organization_id publication_key], unique: true,
              where: "publication_key IS NOT NULL",
              name: "index_knowledge_pages_publication_identity"

    # 8. Via il legame diretto a UN progetto (droppa indice + FK verso projects).
    remove_reference :knowledge_pages, :project, type: :uuid, foreign_key: true
  end

  def down
    add_reference :knowledge_pages, :project, type: :uuid, foreign_key: true

    execute <<~SQL.squish
      UPDATE knowledge_pages
      SET project_id = links.project_id
      FROM (
        SELECT DISTINCT ON (page_id) page_id, project_id
        FROM connections_page_projects
        ORDER BY page_id, created_at, id
      ) links
      WHERE knowledge_pages.id = links.page_id
    SQL

    # Le pagine org-wide non hanno progetto: il modello vecchio non le rappresenta. Fermarsi con un
    # messaggio chiaro invece di far esplodere il NOT NULL con un errore PG opaco.
    orphaned = select_value("SELECT COUNT(*) FROM knowledge_pages WHERE project_id IS NULL").to_i
    if orphaned.positive?
      raise "Rollback impossibile: #{orphaned} pagine org-wide senza progetto. Assegnare loro un progetto o eliminarle prima del rollback."
    end
    change_column_null :knowledge_pages, :project_id, false

    remove_index :knowledge_pages, name: "index_knowledge_pages_publication_identity"
    add_index :knowledge_pages, %i[project_id publication_key], unique: true,
              where: "publication_key IS NOT NULL",
              name: "index_knowledge_pages_publication_identity"

    drop_table :connections_page_groups
    drop_table :connections_page_projects
    remove_column :knowledge_pages, :tags
    remove_reference :knowledge_pages, :organization, type: :uuid, foreign_key: true
  end
end
