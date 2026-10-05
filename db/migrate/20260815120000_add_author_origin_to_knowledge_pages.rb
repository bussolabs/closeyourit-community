# frozen_string_literal: true

# CYRA-419 — la pagina portava un solo nome, quello dell'account il cui accesso è stato usato: chi
# revisionava credeva di leggere il testo di un collega. Qui si separa CHI HA SCRITTO (author_kind +
# author_origin) da CHI POSSIEDE L'ACCESSO (created_by, invariato).
#
# author_kind è NULLABLE di proposito: NULL = origine non registrata. Le pagine già esistenti non
# hanno il dato e attribuirle a una persona per difetto sarebbe esattamente la firma sbagliata che
# questo ticket toglie.
class AddAuthorOriginToKnowledgePages < ActiveRecord::Migration[8.1]
  # Keep this backfill independent of attributes added by later migrations.
  class Page < ActiveRecord::Base
    self.table_name = "knowledge_pages"
  end

  # Knowledge::Page.author_kinds[:agent] — scritto per valore perché una migration non deve dipendere
  # dall'enum del model, che può cambiare dopo di lei.
  AGENT = 1

  def up
    add_column :knowledge_pages, :author_kind, :integer
    add_column :knowledge_pages, :author_origin, :string
    add_index :knowledge_pages, %i[organization_id author_kind],
              name: "index_knowledge_pages_on_organization_id_and_author_kind"

    # Unico backfill difendibile: una proposta ancora in attesa di revisione nasce SOLO dal canale
    # che propone (CLI), quindi è per costruzione scritta da un assistente. Tutto il resto resta
    # NULL: né persona né assistente, semplicemente non registrato.
    Page.reset_column_information
    Page.where(status: 1).update_all(author_kind: AGENT)
  end

  def down
    remove_index :knowledge_pages, name: "index_knowledge_pages_on_organization_id_and_author_kind"
    remove_column :knowledge_pages, :author_origin
    remove_column :knowledge_pages, :author_kind
  end
end
