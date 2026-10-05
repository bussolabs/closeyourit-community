class CreateRbacAuthorization < ActiveRecord::Migration[8.1]
  def change
    # --- Ruoli dinamici (bundle nominati di chiavi-permesso) ---------------------------------
    create_table :authorization_roles, id: :uuid do |t|
      t.timestamps

      t.references :created_by, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.references :organization, type: :uuid, null: false,
                   foreign_key: { on_delete: :cascade }

      t.string :name, null: false
      t.string :color

      t.index [ :organization_id, :name ], unique: true,
              name: "index_authorization_roles_on_organization_and_name"
    end

    # --- Team (gruppo-di-persone) ------------------------------------------------------------
    create_table :teams_teams, id: :uuid do |t|
      t.timestamps

      t.references :created_by, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.references :organization, type: :uuid, null: false,
                   foreign_key: { on_delete: :cascade }

      t.string :name, null: false
      t.string :color

      t.index [ :organization_id, :name ], unique: true,
              name: "index_teams_teams_on_organization_and_name"
    end

    # --- Appartenenza account ↔ team ---------------------------------------------------------
    create_table :connections_team_memberships, id: :uuid do |t|
      t.timestamps

      t.references :account, type: :uuid, null: false,
                   foreign_key: { on_delete: :cascade }
      t.references :team, type: :uuid, null: false,
                   foreign_key: { to_table: :teams_teams, on_delete: :cascade }

      t.index [ :account_id, :team_id ], unique: true,
              name: "index_team_memberships_on_account_and_team"
    end

    # --- Scope del team: team ↔ progetto / team ↔ gruppo-di-progetti --------------------------
    create_table :connections_team_project_accesses, id: :uuid do |t|
      t.timestamps

      t.references :team, type: :uuid, null: false,
                   foreign_key: { to_table: :teams_teams, on_delete: :cascade }
      t.references :project, type: :uuid, null: false,
                   foreign_key: { on_delete: :cascade }

      t.index [ :team_id, :project_id ], unique: true,
              name: "index_team_project_accesses_on_team_and_project"
    end

    create_table :connections_team_group_accesses, id: :uuid do |t|
      t.timestamps

      t.references :team, type: :uuid, null: false,
                   foreign_key: { to_table: :teams_teams, on_delete: :cascade }
      t.references :group, type: :uuid, null: false,
                   foreign_key: { to_table: :projects_groups, on_delete: :cascade }

      t.index [ :team_id, :group_id ], unique: true,
              name: "index_team_group_accesses_on_team_and_group"
    end

    # --- Chiavi-permesso contenute in un ruolo (modifica qui → propaga live) ------------------
    create_table :authorization_role_permissions, id: :uuid do |t|
      t.timestamps

      t.references :role, type: :uuid, null: false,
                   foreign_key: { to_table: :authorization_roles, on_delete: :cascade }

      t.string :permission_key, null: false # validato contro Authorization::Catalog nel model

      t.index [ :role_id, :permission_key ], unique: true,
              name: "index_role_permissions_on_role_and_key"
    end

    # --- Ruoli del team --------------------------------------------------------------------
    create_table :authorization_team_roles, id: :uuid do |t|
      t.timestamps

      t.references :team, type: :uuid, null: false,
                   foreign_key: { to_table: :teams_teams, on_delete: :cascade }
      t.references :role, type: :uuid, null: false,
                   foreign_key: { to_table: :authorization_roles, on_delete: :cascade }

      t.index [ :team_id, :role_id ], unique: true,
              name: "index_team_roles_on_team_and_role"
    end

    # --- Ruoli assegnati direttamente a un utente singolo ------------------------------------
    create_table :authorization_account_roles, id: :uuid do |t|
      t.timestamps

      t.references :account, type: :uuid, null: false,
                   foreign_key: { on_delete: :cascade }
      t.references :organization, type: :uuid, null: false,
                   foreign_key: { on_delete: :cascade } # denormalizzato per query per-org
      t.references :role, type: :uuid, null: false,
                   foreign_key: { to_table: :authorization_roles, on_delete: :cascade }

      t.index [ :account_id, :role_id ], unique: true,
              name: "index_account_roles_on_account_and_role"
    end

    # --- Override personale (eccezione puntuale: attiva/disattiva, batte i ruoli) --------------
    create_table :authorization_account_permissions, id: :uuid do |t|
      t.timestamps

      t.references :account, type: :uuid, null: false,
                   foreign_key: { on_delete: :cascade }
      t.references :organization, type: :uuid, null: false,
                   foreign_key: { on_delete: :cascade }

      t.string  :permission_key, null: false # validato contro Authorization::Catalog nel model
      t.integer :effect, null: false         # enum allow/deny (Authorization::AccountPermission)

      t.index [ :account_id, :organization_id, :permission_key ], unique: true,
              name: "index_account_permissions_on_account_org_and_key"
    end

    # --- Audit dei cambi-permesso (mirror di Ticketing::Event) --------------------------------
    create_table :authorization_events, id: :uuid do |t|
      t.timestamps

      t.references :organization, type: :uuid, null: false,
                   foreign_key: { to_table: :organizations, on_delete: :cascade }
      t.references :actor, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.references :true_actor, type: :uuid, null: true,
                   foreign_key: { to_table: :accounts, on_delete: :nullify }

      t.string :actor_name, null: true        # snapshot del nome attore (resiste a cancellazione)
      t.string :action, null: false           # allow-list nel model (Authorization::Event::ACTIONS)
      t.jsonb  :data, null: false, default: {} # dettagli con label UMANE snapshottate

      t.index [ :organization_id, :created_at ]
    end
  end
end
