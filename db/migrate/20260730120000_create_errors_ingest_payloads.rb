# frozen_string_literal: true

# Staging effimero del payload d'ingest errori (CYRA-211): il corpo dell'evento non viaggia più negli
# argomenti del job in coda — ci va solo l'id di questa riga. Errors::IngestJob la legge, persiste via
# Ingest::Record e la cancella. Vive nel primary (il DB delle code resta leggero). ON DELETE CASCADE:
# se il progetto sparisce, le staging pending spariscono con lui e il job diventa un no-op.
class CreateErrorsIngestPayloads < ActiveRecord::Migration[8.1]
  def change
    create_table :errors_ingest_payloads, id: :uuid do |t|
      t.references :project, null: false, type: :uuid,
                   foreign_key: { to_table: :projects, on_delete: :cascade }
      t.jsonb :payload, null: false, default: {}
      t.datetime :created_at, null: false
      # Unico predicato di PruneIngestPayloadsJob: senza indice il cleanup degli orfani farebbe un seq
      # scan della tabella quando un backlog l'ha gonfiata.
      t.index :created_at
    end
  end
end
