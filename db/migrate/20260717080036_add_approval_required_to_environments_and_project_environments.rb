class AddApprovalRequiredToEnvironmentsAndProjectEnvironments < ActiveRecord::Migration[8.1]
  def up
    # 4a CAPABILITY per-ambiente (CYRA-138, Fase 4 pezzo C1a — FONDAMENTA), stesso pattern tri-state di
    # servers/uptime/secrets: DEFAULT per-ambiente (Types::Environment) + OVERRIDE per-progetto
    # (Connections::ProjectEnvironment). A differenza delle prime 3, il default DB qui è FALSE (non
    # permissivo): l'approvazione è un comportamento che deve essere scelto esplicitamente, mai subito.
    add_column :types_environments, :approval_required, :boolean, null: false, default: false

    # OVERRIDE per-progetto: NULLABLE, nessun default. nil = eredita il default dell'ambiente; true/false
    # = forza il valore per quel progetto (stessa semantica delle altre 3 capability).
    add_column :connections_project_environments, :approval_required, :boolean

    # Backfill dei canonici GIÀ installati (per code): senza, i "production" esistenti resterebbero al
    # default DB (false), mentre la policy voluta è "production parte protetto, staging/development no".
    # Solo production diverge dal default appena impostato: nessuna UPDATE per staging/development.
    say_with_time("backfill approval_required (solo production=true)") { backfill_production_approval_required }
  end

  # Estratto per essere testabile in isolamento (spec/migrations), come backfill_canonical_capabilities
  # in AddCapabilityFlagsToEnvironmentsAndProjectEnvironments. Valore LETTERALE: la migration non
  # dipende dal codice app. L'override sulla join resta nil (eredita il default dell'ambiente).
  def backfill_production_approval_required
    execute "UPDATE types_environments SET approval_required = TRUE WHERE code = 'production'"
  end

  def down
    remove_column :connections_project_environments, :approval_required
    remove_column :types_environments, :approval_required
  end
end
