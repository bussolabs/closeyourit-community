# frozen_string_literal: true

module Clusters
  # A Kubernetes namespace. Linked to a project, alerts about its workloads go to the people
  # following that project (CYAG-22).
  class Namespace < ApplicationRecord
    belongs_to :cluster, class_name: "Clusters::Cluster", inverse_of: :namespaces
    belongs_to :project, class_name: "Projects::Project", optional: true
    belongs_to :environment, class_name: "Types::Environment", optional: true

    has_many :workloads, class_name: "Clusters::Workload", inverse_of: :namespace, dependent: :delete_all

    scope :present, -> { where(gone_at: nil) }

    validates :name, presence: true, uniqueness: { scope: :cluster_id }
    validate :environment_needs_project

    def linked? = project_id.present?

    private

    def environment_needs_project
      errors.add(:environment, :invalid) if environment_id.present? && project_id.blank?
    end
  end
end
