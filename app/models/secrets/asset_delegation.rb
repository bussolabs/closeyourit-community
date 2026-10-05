# frozen_string_literal: true

module Secrets
  class AssetDelegation < ApplicationRecord
    self.table_name = "secrets_asset_delegations"

    belongs_to :asset, class_name: "Secrets::Asset", inverse_of: :delegations
    belongs_to :project, class_name: "Projects::Project"
    belongs_to :created_by, class_name: "Accounts::Account", optional: true
    validates :project_id, uniqueness: { scope: :asset_id }
    validate :shared_asset_and_same_organization

    private

    def shared_asset_and_same_organization
      errors.add(:asset, :invalid) unless asset&.shared?
      errors.add(:project, :invalid) if asset && project && asset.organization_id != project.organization_id
    end
  end
end
