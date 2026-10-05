class AddCapabilityFlagsToEnvironmentsAndProjectEnvironments < ActiveRecord::Migration[8.1]
  def up
    # DEFAULT per-ambiente (Types::Environment): NOT NULL, default permissivo true.
    # La matrice differenziata riguarda solo i 3 canonici (backfill sotto + Types::InstallDefaults);
    # gli ambienti custom creati a mano nascono "capaci di tutto salvo opt-out".
    add_column :types_environments, :servers_enabled, :boolean, null: false, default: true
    add_column :types_environments, :uptime_enabled,  :boolean, null: false, default: true
    add_column :types_environments, :secrets_enabled, :boolean, null: false, default: true

    # OVERRIDE per-progetto (Connections::ProjectEnvironment): NULLABLE, nessun default.
    # nil = eredita il default dell'ambiente; true/false = forza il valore per quel progetto.
    add_column :connections_project_environments, :servers_enabled, :boolean
    add_column :connections_project_environments, :uptime_enabled,  :boolean
    add_column :connections_project_environments, :secrets_enabled, :boolean

    # Backfill dei 3 canonici GIÀ installati nelle org esistenti (per code): senza, gli ambienti
    # staging/development esistenti resterebbero al default DB (tutto true), in contrasto con la matrice.
    say_with_time("backfill matrice capability (production/staging/development)") { backfill_canonical_capabilities }
  end

  # Estratto per essere testabile in isolamento (spec/migrations). Valori LETTERALI: la migration non
  # dipende dal codice app. Gli override sulla join restano nil (eredita il default dell'ambiente).
  def backfill_canonical_capabilities
    execute "UPDATE types_environments SET servers_enabled = TRUE,  uptime_enabled = TRUE,  secrets_enabled = TRUE WHERE code = 'production'"
    execute "UPDATE types_environments SET servers_enabled = TRUE,  uptime_enabled = FALSE, secrets_enabled = TRUE WHERE code = 'staging'"
    execute "UPDATE types_environments SET servers_enabled = FALSE, uptime_enabled = FALSE, secrets_enabled = TRUE WHERE code = 'development'"
  end

  def down
    remove_column :connections_project_environments, :secrets_enabled
    remove_column :connections_project_environments, :uptime_enabled
    remove_column :connections_project_environments, :servers_enabled
    remove_column :types_environments, :secrets_enabled
    remove_column :types_environments, :uptime_enabled
    remove_column :types_environments, :servers_enabled
  end
end
