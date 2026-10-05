# frozen_string_literal: true

# Stato di revisione di una pagina KB (CYRA-298). Una pagina proposta da un assistente nasce
# `in_review`: resta fuori da ricerca, RAG, correlate e liste finché un umano non l'accetta.
#
# default 0 = published: le pagine esistenti restano esattamente com'erano, nessun backfill.
# consolidated_at/source_path tracciano il secondo passo (il documento versionato nel repo della
# knowledge base): accettata ma non ancora scritta su file = consolidated_at nil.
class AddReviewToKnowledgePages < ActiveRecord::Migration[8.1]
  def change
    add_column :knowledge_pages, :status, :integer, default: 0, null: false
    add_column :knowledge_pages, :review_note, :text
    add_column :knowledge_pages, :reviewed_at, :datetime
    add_column :knowledge_pages, :consolidated_at, :datetime
    add_column :knowledge_pages, :source_path, :string
    add_reference :knowledge_pages, :reviewed_by, type: :uuid, null: true,
                                                  foreign_key: { to_table: :accounts }

    # La coda di revisione e le liste normali filtrano sempre per organizzazione + stato.
    add_index :knowledge_pages, %i[organization_id status]
  end
end
