# frozen_string_literal: true

# CYRA-721 — leggere i valori dei secret e gestirli sono due permessi separati: `secrets.manage` non
# implica più `secrets.read`. Il ruolo Maintainer delle organizzazioni già esistenti è nato con la sola
# `secrets.manage` (InstallDefaultRoles imposta le chiavi SOLO quando crea il ruolo, per non
# sovrascrivere le personalizzazioni dell'owner): senza questo backfill, al deploy chi ha quel ruolo
# smetterebbe di vedere i valori che vedeva ieri, e la separazione si presenterebbe come un guasto.
# Tocca il solo Maintainer, come DEFAULTS: dare una chiave `dangerous` a un ruolo creato a mano
# sarebbe un'escalation che nessuno ha chiesto. Idempotente.
class BackfillSecretsReadForMaintainers < ActiveRecord::Migration[8.1]
  ROLE_NAME = "Maintainer"
  PERMISSION_KEY = "secrets.read"

  class Role < ActiveRecord::Base
    self.table_name = "authorization_roles"
  end

  class RolePermission < ActiveRecord::Base
    self.table_name = "authorization_role_permissions"
  end

  def up
    RolePermission.reset_column_information
    now = Time.current

    rows = Role.where(name: ROLE_NAME).pluck(:id).map do |role_id|
      { role_id: role_id, permission_key: PERMISSION_KEY, created_at: now, updated_at: now }
    end
    return if rows.empty?

    # ON CONFLICT DO NOTHING sull'indice unico [role_id, permission_key].
    RolePermission.insert_all(rows, unique_by: :index_role_permissions_on_role_and_key)
  end

  # Revoca solo dove il backfill può averla messa (i ruoli Maintainer): togliere `secrets.read` a
  # chiunque ce l'abbia cancellerebbe grant fatti a mano che questa migration non ha mai toccato.
  def down
    RolePermission.where(permission_key: PERMISSION_KEY, role_id: Role.where(name: ROLE_NAME).select(:id)).delete_all
  end
end
