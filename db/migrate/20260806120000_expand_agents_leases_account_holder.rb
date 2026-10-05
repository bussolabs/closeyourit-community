# frozen_string_literal: true

# CYRA-293 — Il lease diventa polimorfo sul titolare (EXPAND-ONLY). Finora la mutua esclusione su un
# ticket valeva solo fra host automator: `host_id` era NOT NULL, quindi una persona non poteva
# dichiarare la presa in carico e un umano poteva lavorare un ticket sotto lease agente senza saperlo.
#
# La riga resta UNA per ticket (index_agents_leases_unique_ticket è l'autorità): il titolare diventa
# `host_id` XOR `account_id`. Mettere gli umani in una tabella separata NON darebbe mutua esclusione —
# due tabelle non si escludono a vicenda, ed è esattamente il bug da chiudere.
#
# Migration ADDITIVA: nessun backfill, i lease esistenti restano host-owned e i rami host non cambiano.
class ExpandAgentsLeasesAccountHolder < ActiveRecord::Migration[8.1]
  TABLES = %i[agents_leases agents_leases_tombstones].freeze

  def up
    TABLES.each do |table|
      add_reference table, :account, type: :uuid, null: true, index: true,
                                     foreign_key: { to_table: :accounts, on_delete: :cascade }
      change_column_null table, :host_id, true

      # Invariante del titolare: esattamente uno fra host e account. Vieta sia il lease senza titolare
      # (bloccherebbe il ticket fino alla scadenza senza che nessuno possa rilasciarlo) sia quello con
      # due titolari, che renderebbe ambigua ogni verifica di possesso.
      add_check_constraint table,
                           "(host_id IS NOT NULL) <> (account_id IS NOT NULL)",
                           name: "#{table}_holder"
    end

    # L'idempotenza del tombstone è retta da un unique index che include il titolare. Quello esistente
    # su (ticket_id, host_id, run_id) NON vincola le righe a host_id NULL — in PostgreSQL due NULL non
    # collidono mai — quindi senza questo gemello parziale due release umani dello stesso run
    # creerebbero due tombstone e create_or_find_by! perderebbe la sua garanzia sotto concorrenza.
    add_index :agents_leases_tombstones, %i[ticket_id account_id run_id],
              unique: true, where: "account_id IS NOT NULL",
              name: "index_agents_lease_tombstones_account_idempotency"

    # Un titolare account non ha identità di lavoro agente: nessuna fase eseguibile da pinnare, nessuno
    # slug agent da consegnare. Il vecchio vincolo pretendeva sempre l'una o l'altro; ora il terzo ramo
    # ammette il lease umano, che le ha entrambe NULL. Gemello di Agents::Lease#dual_stack_identity.
    # I due rami host restano vincolati ad account_id NULL: senza quella condizione un lease
    # account-owned che portasse fase+impronta soddisferebbe il secondo ramo e il DB lo accetterebbe,
    # mentre il modello lo rifiuta — cioè il vincolo non sarebbe più il gemello della validazione ma
    # una rete più larga, che un insert_all o un update_column attraverserebbe senza accorgersene.
    remove_check_constraint :agents_leases, name: "agents_leases_work_identity"
    add_check_constraint :agents_leases,
                         "(account_id IS NOT NULL AND execution_phase IS NULL AND profile_digest IS NULL " \
                         "AND agent IS NULL) OR " \
                         "(account_id IS NULL AND (" \
                         "(execution_phase IS NOT NULL AND profile_digest IS NOT NULL) OR " \
                         "(execution_phase IS NULL AND profile_digest IS NULL AND agent IS NOT NULL)))",
                         name: "agents_leases_work_identity"
  end

  # Reversibile solo su un DB privo di lease umani: ripristinare NOT NULL su host_id con righe a
  # host_id NULL perderebbe i titolari account. Onesto sul limite, come la down di CYAU-96.
  def down
    if select_value("SELECT EXISTS (SELECT 1 FROM agents_leases WHERE host_id IS NULL)")
      raise ActiveRecord::IrreversibleMigration,
            "Esistono lease con titolare account (host_id NULL): il ripristino di NOT NULL su " \
            "agents_leases.host_id perderebbe dati. Rilasciare quei lease prima di invertire."
    end

    remove_check_constraint :agents_leases, name: "agents_leases_work_identity"
    add_check_constraint :agents_leases,
                         "(execution_phase IS NOT NULL AND profile_digest IS NOT NULL) OR " \
                         "(execution_phase IS NULL AND profile_digest IS NULL AND agent IS NOT NULL)",
                         name: "agents_leases_work_identity"

    remove_index :agents_leases_tombstones, name: "index_agents_lease_tombstones_account_idempotency"

    TABLES.each do |table|
      remove_check_constraint table, name: "#{table}_holder"
      change_column_null table, :host_id, false
      remove_reference table, :account, foreign_key: { to_table: :accounts }
    end
  end
end
