# frozen_string_literal: true

# CYAU-96 — Lease host-first (EXPAND-ONLY). Il lease diventa host-owned: la fase eseguibile
# (execution_phase) e l'impronta del profilo di esecuzione (profile_digest = Agents::PhaseProfile#digest)
# sono pinnate sulla riga, e la stringa `agent` (slug dell'agente tipizzato) smette di essere
# obbligatoria. Migration ADDITIVA: NESSUN backfill — i lease legacy restano dual-stack (agent presente,
# execution_phase/profile_digest NULL) e sono gestiti dai rami legacy di acquire/deliver finché il
# prompt-mode (CYRA-132) non viene ritirato (CYAU-94). Il contract (drop di `agent`) è una release a valle.
class ExpandAgentsLeasesHostFirst < ActiveRecord::Migration[8.1]
  def up
    change_table :agents_leases, bulk: true do |t|
      t.string :execution_phase
      t.string :profile_digest
    end
    change_column_null :agents_leases, :agent, true

    # Invariante dual-stack (gemello della validazione Agents::Lease#dual_stack_identity): un lease è o
    # host-first COMPLETO (fase + impronta) o legacy puro (agent, senza fase/impronta). Vieta i record
    # malformati — vuoti o host-first parziali — che bloccherebbero la coda e non sarebbero mai consegnabili.
    add_check_constraint :agents_leases,
                         "(execution_phase IS NOT NULL AND profile_digest IS NOT NULL) OR " \
                         "(execution_phase IS NULL AND profile_digest IS NULL AND agent IS NOT NULL)",
                         name: "agents_leases_work_identity"
  end

  # Reversibile solo su un DB privo di lease host-first: ripristinare NOT NULL su `agent` con righe a
  # `agent IS NULL` (host-first) perderebbe l'integrità. Onesto sul limite, come la down di CYAU-83.
  def down
    if select_value("SELECT EXISTS (SELECT 1 FROM agents_leases WHERE agent IS NULL)")
      raise ActiveRecord::IrreversibleMigration,
            "Esistono lease host-first (agent NULL): il ripristino di NOT NULL su agents_leases.agent " \
            "perderebbe dati. Rimuovere/retire quei lease prima di invertire."
    end

    remove_check_constraint :agents_leases, name: "agents_leases_work_identity"
    change_column_null :agents_leases, :agent, false
    change_table :agents_leases, bulk: true do |t|
      t.remove :execution_phase
      t.remove :profile_digest
    end
  end
end
