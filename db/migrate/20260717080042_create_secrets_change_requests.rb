class CreateSecretsChangeRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :secrets_change_requests, id: :uuid do |t|
      t.timestamps

      # Tenancy denormalizzata (scoping/query per org, coerente con Secrets::Event/Ticketing::Event).
      t.references :organization, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      # Radice di scoping: la richiesta appartiene a un progetto.
      t.references :project, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      # Ambiente PROTETTO su cui la modifica è stata intercettata.
      t.references :environment, type: :uuid, null: false,
                   foreign_key: { to_table: :types_environments, on_delete: :cascade }

      # Chi ha richiesto la modifica (nullify: la richiesta/l'audit sopravvive alla cancellazione account,
      # come Secrets::Event#actor). Immutabile dopo la creazione (vedi attr_readonly sul model).
      t.references :requested_by, type: :uuid,
                   foreign_key: { to_table: :accounts, on_delete: :nullify }, null: true
      # Chi ha deciso (approvato/rifiutato); nil finché la richiesta resta pending.
      t.references :decided_by, type: :uuid,
                   foreign_key: { to_table: :accounts, on_delete: :nullify }, null: true
      # Versione sorgente opzionale (rollback): la richiesta può nascere da un ripristino puntuale.
      t.references :source_version, type: :uuid,
                   foreign_key: { to_table: :secrets_versions, on_delete: :nullify }, null: true

      # Nome del secret target: UPPER_SNAKE come Secrets::Variable#name (stesso NAME_FORMAT sul model).
      t.string :name, null: false
      # "set" (crea/aggiorna un valore) o "delete" (cancella il secret). Immutabile dopo la creazione.
      t.string :action, null: false
      # Valore proposto, cifrato at-rest (encrypts :value sul model, come Secrets::Variable/Version).
      # Nullable: una richiesta di cancellazione non porta un valore.
      t.text :value
      # pending (in attesa) / applied (approvata e applicata) / rejected (rifiutata) / cancelled
      # (ritirata dal richiedente). L'applicazione vera arriva nei pezzi successivi (C1b/C2).
      t.string :status, null: false, default: "pending"
      t.datetime :decided_at
      t.text :reason

      # Workhorse della futura coda "richieste in attesa" per progetto (C1b/C2). L'indice su
      # organization_id arriva già gratis da t.references sopra (default index: true) — non duplicato qui.
      t.index %i[project_id status]
    end
  end
end
