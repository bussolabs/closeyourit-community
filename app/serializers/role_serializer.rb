# frozen_string_literal: true

# Ruolo RBAC per la CLI: bundle nominato di chiavi-permesso (Authorization::Catalog).
class RoleSerializer < ApplicationSerializer
  attributes :id, :name, :color, :created_at

  attribute :permission_keys, &:permission_keys
end
