# frozen_string_literal: true

module Secrets
  class Asset < ApplicationRecord
    self.table_name = "secrets_assets"

    TYPES = %w[p8 p12 jks keystore service_account_json].freeze

    belongs_to :organization, class_name: "Organizations::Organization"
    belongs_to :project, class_name: "Projects::Project", optional: true
    belongs_to :environment, class_name: "Types::Environment", optional: true
    belongs_to :created_by, class_name: "Accounts::Account", optional: true
    has_many :versions, class_name: "Secrets::AssetVersion", dependent: :destroy, inverse_of: :asset
    has_many :delegations, class_name: "Secrets::AssetDelegation", dependent: :destroy, inverse_of: :asset
    has_many :delegated_projects, through: :delegations, source: :project

    attr_readonly :organization_id, :project_id
    normalizes :name, with: ->(value) { value.to_s.strip }
    normalizes :description, with: ->(value) { value.to_s.strip.presence }

    validates :name, presence: true, uniqueness: { scope: %i[organization_id project_id environment_id] }
    validates :asset_type, inclusion: { in: TYPES }
    validate :scope_integrity

    scope :active, -> { where(archived_at: nil) }
    scope :ordered, -> { order(:name) }

    def shared? = project_id.nil?
    def archived? = archived_at.present?
    def current_version = versions.order(number: :desc).first

    private

    def scope_integrity
      errors.add(:project, :invalid) if project && project.organization_id != organization_id
      errors.add(:environment, :invalid) if environment && !organization.environments.exists?(environment.id)
    end
  end
end
