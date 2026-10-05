# frozen_string_literal: true

# CYRA-768 — la data oltre la quale la pagina va riletta. NULL = non scade mai (le note semplici,
# e ogni pagina finché nessuno la valorizza): il conto lo mette chi accetta, chi crea e chi riscrive.
#
# NESSUN backfill qui, di proposito: applicare i default a tutto il parco in un colpo farebbe
# scadere insieme centinaia di pagine e la coda nascerebbe già ingestibile. Lo fa
# Knowledge::BackfillReviewAfterJob, che spalma le date su una finestra di giorni.
class AddReviewAfterToKnowledgePages < ActiveRecord::Migration[8.1]
  def change
    add_column :knowledge_pages, :review_after, :datetime
    # La coda si legge SEMPRE dentro un'organizzazione: l'indice segue quella lettura.
    add_index :knowledge_pages, [ :organization_id, :review_after ]
  end
end
