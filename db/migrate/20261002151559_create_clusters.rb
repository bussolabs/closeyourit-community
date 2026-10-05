# frozen_string_literal: true

# Kubernetes clusters watched by closeyourit-kube (CYAG-22).
class CreateClusters < ActiveRecord::Migration[8.1]
  def change
    create_table :clusters_clusters, id: :uuid do |t|
      t.references :organization, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :created_by, type: :uuid, foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.string :name, null: false
      t.string :color
      t.string :token_digest, null: false
      t.string :token_prefix, null: false
      t.datetime :revoked_at
      t.integer :status, null: false, default: 0
      t.string :kubernetes_version
      t.string :provider
      t.string :observer_version
      t.boolean :metrics_available, null: false, default: false
      t.boolean :truncated, null: false, default: false
      t.datetime :last_snapshot_at
      t.string :last_snapshot_id
      t.timestamps
      t.index %i[organization_id name], unique: true
      t.index :token_digest, unique: true
    end

    create_table :clusters_nodes, id: :uuid do |t|
      t.references :cluster, type: :uuid, null: false, foreign_key: { to_table: :clusters_clusters, on_delete: :cascade }, index: false
      t.string :name, null: false
      t.boolean :ready, null: false, default: false
      t.jsonb :pressure, null: false, default: {}
      t.boolean :unschedulable, null: false, default: false
      t.boolean :being_removed, null: false, default: false
      t.bigint :cpu_capacity_millicores
      t.bigint :memory_capacity_bytes
      t.bigint :cpu_usage_millicores
      t.bigint :memory_usage_bytes
      t.integer :pods, null: false, default: 0
      t.datetime :node_created_at
      t.string :provider_id
      t.datetime :not_ready_since
      t.datetime :not_ready_alerted_at
      t.datetime :pressure_alerted_at
      t.datetime :gone_at
      t.timestamps
      t.index %i[cluster_id name], unique: true
    end

    create_table :clusters_namespaces, id: :uuid do |t|
      t.references :cluster, type: :uuid, null: false, foreign_key: { to_table: :clusters_clusters, on_delete: :cascade }, index: false
      t.string :name, null: false
      t.references :project, type: :uuid, foreign_key: { to_table: :projects, on_delete: :nullify }
      t.references :environment, type: :uuid, foreign_key: { to_table: :types_environments, on_delete: :nullify }
      t.datetime :gone_at
      t.timestamps
      t.index %i[cluster_id name], unique: true
    end

    create_table :clusters_workloads, id: :uuid do |t|
      t.references :cluster, type: :uuid, null: false, foreign_key: { to_table: :clusters_clusters, on_delete: :cascade }, index: false
      t.references :namespace, type: :uuid, null: false, foreign_key: { to_table: :clusters_namespaces, on_delete: :cascade }
      t.string :kind, null: false
      t.string :name, null: false
      t.integer :desired, null: false, default: 0
      t.integer :ready, null: false, default: 0
      t.integer :available, null: false, default: 0
      t.string :image
      t.integer :restarts_total, null: false, default: 0
      t.jsonb :restart_marks, null: false, default: []
      t.string :last_reason
      t.datetime :degraded_since
      t.datetime :degraded_alerted_at
      t.datetime :crashloop_alerted_at
      t.datetime :gone_at
      t.timestamps
      t.index %i[cluster_id namespace_id kind name], unique: true, name: "index_clusters_workloads_identity"
    end

    create_table :clusters_events, id: :uuid do |t|
      t.references :cluster, type: :uuid, null: false, foreign_key: { to_table: :clusters_clusters, on_delete: :cascade }, index: false
      t.string :namespace_name
      t.string :reason, null: false
      t.string :object_kind
      t.string :object_name
      t.string :message
      t.integer :count, null: false, default: 0
      t.datetime :last_seen_at, null: false
      t.timestamps
      t.index %i[cluster_id last_seen_at]
      t.index %i[cluster_id reason object_kind object_name last_seen_at], unique: true, name: "index_clusters_events_identity"
    end
  end
end
