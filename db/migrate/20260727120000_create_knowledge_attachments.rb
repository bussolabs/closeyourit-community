# frozen_string_literal: true

# Allegati di una pagina KB (CYRA-176): un record = un file, come Projects::Document. Fino a ieri la
# pagina era solo testo e i file stavano nei documenti di PROGETTO; qui il file appartiene alla
# PAGINA che lo spiega e muore con lei (FK cascade + dependent: :destroy sul model).
#
# Il binario NON sta qui: vive in ActiveStorage (S3 privato in staging/production). Questa tabella
# porta solo i metadati editabili — title rinominabile separato dal filename originale del blob.
class CreateKnowledgeAttachments < ActiveRecord::Migration[8.1]
  def change
    create_table :knowledge_attachments, id: :uuid do |t|
      t.timestamps

      # Cascade: gli allegati sono contenuto della pagina, non entità autonome. Senza, resterebbero
      # righe orfane con un blob a pagamento su S3 e nessuno schermo da cui vederle.
      t.references :page, type: :uuid, null: false,
                          foreign_key: { to_table: :knowledge_pages, on_delete: :cascade }
      # Nullify: l'allegato sopravvive alla cancellazione dell'account che l'ha caricato (stessa
      # scelta di projects_documents.created_by_id — il file resta utile, l'attribuzione no).
      t.references :created_by, type: :uuid, null: true,
                                foreign_key: { to_table: :accounts, on_delete: :nullify }

      t.string :title, null: false
      t.text :description
      # Ordinamento manuale dell'elenco; il tie-break resta created_at (vedi scope :ordered).
      t.integer :position, null: false, default: 0

      t.index %i[page_id created_at]
    end
  end
end
