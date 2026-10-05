# frozen_string_literal: true

# CYRA-940 — a new catalog key does not reach the roles that already exist: InstallDefaultRoles sets
# the permissions ONLY when it creates the role, so the owner's customizations are never overwritten.
# Without this backfill the Help desk page would be visible to the owner alone after the deploy.
# Mirrors DEFAULTS: Administrator (:all) and Maintainer. Idempotent.
class BackfillHelpdeskManagePermission < ActiveRecord::Migration[8.1]
  ROLE_NAMES = %w[Administrator Maintainer].freeze
  PERMISSION_KEY = "helpdesk.manage"

  class Role < ActiveRecord::Base
    self.table_name = "authorization_roles"
  end

  class RolePermission < ActiveRecord::Base
    self.table_name = "authorization_role_permissions"
  end

  def up
    RolePermission.reset_column_information
    now = Time.current

    rows = Role.where(name: ROLE_NAMES).pluck(:id).map do |role_id|
      { role_id: role_id, permission_key: PERMISSION_KEY, created_at: now, updated_at: now }
    end
    return if rows.empty?

    # ON CONFLICT DO NOTHING on the unique index [role_id, permission_key].
    RolePermission.insert_all(rows, unique_by: :index_role_permissions_on_role_and_key)
  end

  # Revokes only where the backfill can have granted: a grant made by hand on another role stays.
  def down
    RolePermission.where(permission_key: PERMISSION_KEY, role_id: Role.where(name: ROLE_NAMES).select(:id)).delete_all
  end
end
