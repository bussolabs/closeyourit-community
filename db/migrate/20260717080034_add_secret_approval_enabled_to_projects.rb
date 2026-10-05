class AddSecretApprovalEnabledToProjects < ActiveRecord::Migration[8.1]
  def change
    # Master opt-in per-progetto dell'approvazione a due (4-eyes) sui secret (CYRA-138, Fase 4 pezzo
    # C1a — FONDAMENTA). Pattern IDENTICO a roadmap_enabled: default false, nessun backfill (nessun
    # progetto esistente ha mai avuto questo comportamento, quindi non c'è nulla da "far partire attivo").
    add_column :projects, :secret_approval_enabled, :boolean, default: false, null: false
  end
end
