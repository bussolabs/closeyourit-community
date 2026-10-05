# frozen_string_literal: true

# Le chiavi nuove del catalogo (CYRA-528: seo.manage, seo.triage) non arrivano da sole ai ruoli già
# esistenti: InstallDefaultRoles imposta i permessi SOLO quando crea il ruolo, per non sovrascrivere
# le personalizzazioni dell'owner. Senza questo backfill, dopo il deploy dichiarare un sito o
# triagiare un rilievo sarebbe possibile al solo owner (che passa dal ramo privilegiato prima di
# ogni controllo di chiave) e invisibile a chi ha il ruolo Administrator/Maintainer/Triager.
# Idempotente. Rispecchia InstallDefaultRoles::DEFAULTS.
class BackfillSeoPermissions < ActiveRecord::Migration[8.1]
  # Administrator ha :all nel catalogo → entrambe. Maintainer configura → manage. Triager decide
  # cosa fare di ciò che è stato trovato → triage.
  GRANTS = {
    "Administrator" => %w[seo.manage seo.triage],
    "Maintainer" => %w[seo.manage],
    "Triager" => %w[seo.triage]
  }.freeze

  class Role < ActiveRecord::Base
    self.table_name = "authorization_roles"
  end

  class RolePermission < ActiveRecord::Base
    self.table_name = "authorization_role_permissions"
  end

  def up
    RolePermission.reset_column_information
    now = Time.current

    rows = GRANTS.flat_map do |name, keys|
      Role.where(name: name).pluck(:id).flat_map do |role_id|
        keys.map { |key| { role_id: role_id, permission_key: key, created_at: now, updated_at: now } }
      end
    end
    return if rows.empty?

    # ON CONFLICT DO NOTHING sull'indice unico [role_id, permission_key].
    RolePermission.insert_all(rows, unique_by: :index_role_permissions_on_role_and_key)
  end

  def down
    RolePermission.where(permission_key: GRANTS.values.flatten.uniq).delete_all
  end
end
