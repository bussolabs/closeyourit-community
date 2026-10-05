# frozen_string_literal: true

# Cronologia versioni di una fonte OSSERVATA (Projects::Source): una riga per ogni versione di un tool
# davvero vista sul progetto, con la finestra dalla data di optin (first_seen_at) a quella di optout
# (last_seen_at, l'ultimo istante prima del passaggio a una versione nuova). Alimentata dallo stesso
# hook dell'ingest (Projects::Source.track!) accanto all'upsert di projects_sources. Append per versione:
# la chiave d'identità è [fonte, versione]. Il pulsante "Cronologia" della card Monitoring tools legge qui.
class CreateProjectsSourceVersions < ActiveRecord::Migration[8.1]
  def change
    create_table :projects_source_versions, id: :uuid do |t|
      t.timestamps

      t.references :source, type: :uuid, null: false,
                   foreign_key: { to_table: :projects_sources, on_delete: :cascade }

      t.string :version, null: false
      t.datetime :first_seen_at, null: false
      t.datetime :last_seen_at, null: false

      t.index %i[source_id version], unique: true
      t.index %i[source_id first_seen_at]
    end

    # Backfill delle fonti già esistenti: senza, la cronologia partirebbe vuota fino al prossimo ingest
    # pur avendo la fonte già version/first_seen_at/last_seen_at. Solo in avanti (il rollback droppa la
    # tabella comunque). Logica idempotente su Projects::Source (SQL puro).
    reversible do |dir|
      dir.up { Projects::Source.backfill_version_history! }
    end
  end
end
