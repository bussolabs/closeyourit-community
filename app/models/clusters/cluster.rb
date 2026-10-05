# frozen_string_literal: true

module Clusters
  # A Kubernetes cluster watched by one closeyourit-kube observer. The cyi_k_ token lives here as a
  # SHA-256 digest: the token is the cluster identity (CYAG-22).
  class Cluster < ApplicationRecord
    belongs_to :organization, class_name: "Organizations::Organization", inverse_of: :clusters
    belongs_to :created_by, class_name: "Accounts::Account", optional: true

    has_many :nodes, class_name: "Clusters::Node", inverse_of: :cluster, dependent: :delete_all
    has_many :namespaces, class_name: "Clusters::Namespace", inverse_of: :cluster, dependent: :delete_all
    has_many :workloads, class_name: "Clusters::Workload", inverse_of: :cluster, dependent: :delete_all
    has_many :events, class_name: "Clusters::Event", inverse_of: :cluster, dependent: :delete_all

    enum :status, { pending: 0, up: 1, down: 2, paused: 3 }, prefix: :status

    normalizes :name, with: ->(value) { value.to_s.strip }
    validates :name, presence: true, uniqueness: { scope: :organization_id }
    validates :token_digest, presence: true, uniqueness: true
    validates :token_prefix, presence: true

    scope :active, -> { where(revoked_at: nil) }
    scope :stale, lambda {
      active.status_up.where(last_snapshot_at: ...Clusters::Constants::STALE_AFTER_SECONDS.seconds.ago)
    }

    def revoked? = revoked_at.present?
  end
end
