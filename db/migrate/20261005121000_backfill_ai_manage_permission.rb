# frozen_string_literal: true

# ai.manage is new (CYRA-914): existing Administrator roles got :all only when they were created, so
# they would not see the organization AI page. Maintainer manages content, not providers and keys.
class BackfillAiManagePermission < ActiveRecord::Migration[8.1]
  class Role < ActiveRecord::Base
    self.table_name = "authorization_roles"
  end

  class RolePermission < ActiveRecord::Base
    self.table_name = "authorization_role_permissions"
  end

  def up
    now = Time.current
    rows = Role.where(name: "Administrator").pluck(:id).map do |role_id|
      { role_id:, permission_key: "ai.manage", created_at: now, updated_at: now }
    end
    return if rows.empty?

    RolePermission.insert_all(rows, unique_by: :index_role_permissions_on_role_and_key)
  end

  def down
    RolePermission.where(permission_key: "ai.manage").delete_all
  end
end
