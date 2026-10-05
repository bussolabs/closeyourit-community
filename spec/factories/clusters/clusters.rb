# frozen_string_literal: true

FactoryBot.define do
  factory :cluster, class: "Clusters::Cluster" do
    organization
    sequence(:name) { |n| "cluster-#{n}" }
    sequence(:token_digest) { |n| Digest::SHA256.hexdigest("cyi_k_factory#{n}") }
    token_prefix { "cyi_k_factory" }
    status { :up }
    last_snapshot_at { Time.current }
  end

  factory :cluster_node, class: "Clusters::Node" do
    cluster
    sequence(:name) { |n| "node-#{n}" }
    ready { true }
  end

  factory :cluster_namespace, class: "Clusters::Namespace" do
    cluster
    sequence(:name) { |n| "namespace-#{n}" }
  end

  factory :cluster_workload, class: "Clusters::Workload" do
    cluster
    namespace { association :cluster_namespace, cluster: }
    kind { "Deployment" }
    sequence(:name) { |n| "app-#{n}" }
    desired { 1 }
    ready { 1 }
    available { 1 }
  end
end
