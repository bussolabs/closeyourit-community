# frozen_string_literal: true

class Secrets::Provision < ApplicationRecord
  belongs_to :organization, class_name: "Organizations::Organization"
  belongs_to :source_project, class_name: "Projects::Project", inverse_of: :source_secret_provisions
  belongs_to :destination_project, class_name: "Projects::Project", inverse_of: :destination_secret_provisions
  belongs_to :source_environment, class_name: "Types::Environment"
  belongs_to :destination_environment, class_name: "Types::Environment"
  belongs_to :token, class_name: "Projects::Token"
  belongs_to :secret_variable, class_name: "Secrets::Variable"
  belongs_to :created_by, class_name: "Accounts::Account", optional: true

  enum :status, { pending_sync: 0, ready: 1, failed: 2 }, default: :pending_sync

  attr_readonly :organization_id, :source_project_id, :destination_project_id,
                :source_environment_id, :destination_environment_id, :token_id,
                :secret_variable_id, :created_by_id, :secret_name, :idempotency_key,
                :request_fingerprint, :sync_github

  normalizes :idempotency_key, with: ->(value) { value.to_s.strip }
  normalizes :secret_name, with: ->(value) { value.to_s.strip.upcase }

  validates :idempotency_key, :request_fingerprint, :secret_name, presence: true
  validates :idempotency_key, uniqueness: { scope: :organization_id }
  validate :tenant_integrity, on: :create

  private

  def tenant_integrity
    return if organization.blank? || source_project.blank? || destination_project.blank?

    errors.add(:source_project, :invalid) unless source_project.organization_id == organization_id
    errors.add(:destination_project, :invalid) unless destination_project.organization_id == organization_id
  end
end
