# frozen_string_literal: true

module Authorization
  # Una chiave-permesso contenuta in un ruolo. La chiave deve esistere nel Catalog statico
  # (rules/lookup-tables.md: discriminatore in codice). Modifica qui → propaga live ai portatori.
  class RolePermission < ApplicationRecord
    belongs_to :role,
               class_name: "Authorization::Role",
               inverse_of: :role_permissions

    validates :permission_key, presence: true,
              inclusion: { in: Authorization::Catalog.keys },
              uniqueness: { scope: :role_id }
  end
end
