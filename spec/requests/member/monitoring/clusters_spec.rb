# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Member::Monitoring::Clusters", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }
  let(:member) { create(:account) }
  let(:now) { Time.current }

  before do
    create(:membership, account: owner, organization:, role: :owner)
    create(:membership, account: member, organization:, role: :member)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  def cluster_with_state
    cluster = create(:cluster, organization:, name: "production-eu", kubernetes_version: "v1.31.4", provider: "hcloud")
    create(:cluster_node, cluster:, name: "pool-a", cpu_usage_millicores: 1000, cpu_capacity_millicores: 4000,
                          memory_usage_bytes: 2.gigabytes, memory_capacity_bytes: 8.gigabytes)
    create(:cluster_node, cluster:, name: "pool-b", ready: false, not_ready_since: 5.minutes.ago, not_ready_alerted_at: 3.minutes.ago)
    namespace = create(:cluster_namespace, cluster:, name: "shop")
    create(:cluster_workload, cluster:, namespace:, name: "checkout", desired: 3, ready: 1, last_reason: "CrashLoopBackOff",
                              crashloop_alerted_at: 1.minute.ago, image: "shop/checkout:2.14.0")
    create(:cluster_workload, cluster:, namespace:, name: "web")
    cluster
  end

  describe "GET index" do
    it "shows the empty state with the add button to a manager" do
      sign_in(owner)
      get member_monitoring_clusters_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="clusters-empty"', 'data-test="clusters-empty-new"')
    end

    it "lists clusters with their status and figures" do
      cluster = cluster_with_state
      create(:cluster, organization:, name: "staging")
      sign_in(owner)

      get member_monitoring_clusters_path

      expect(response.body).to include("production-eu", "staging", "k8s v1.31.4 · hcloud")
      expect(response.body).to include("2 things to look at").or include("2 cose da guardare")
      expect(response.body).to include("data-test=\"cluster-#{cluster.id}\"")
    end

    it "never shows clusters of another organization" do
      create(:cluster, name: "foreign-cluster")
      sign_in(owner)
      get member_monitoring_clusters_path
      expect(response.body).not_to include("foreign-cluster")
    end

    it "refuses people without servers.view" do
      sign_in(member)
      get member_monitoring_clusters_path
      expect(response).to redirect_to(root_path)
    end
  end

  describe "adding a cluster" do
    it "shows the token once, with the install command, and keeps only its digest" do
      sign_in(owner)
      get new_member_monitoring_cluster_path
      expect(response).to have_http_status(:ok)

      post member_monitoring_clusters_path, params: { name: "lab", color: "violet", confirm: "1" }

      expect(response).to have_http_status(:created)
      cluster = organization.clusters.find_by!(name: "lab")
      secret = response.body[/cyi_k_[A-Za-z0-9]{40}/]
      expect(secret).to be_present
      expect(cluster.token_digest).to eq(Digest::SHA256.hexdigest(secret))
      expect(response.body).to include("helm install closeyourit-kube", 'data-test="cluster-waiting"')
      expect(session.to_hash.values.join).not_to include(secret)

      get member_monitoring_cluster_path(cluster)
      expect(response.body).not_to include(secret)
    end

    it "refuses a duplicate name" do
      create(:cluster, organization:, name: "lab")
      sign_in(owner)
      post member_monitoring_clusters_path, params: { name: "lab", confirm: "1" }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "is closed to people without servers.manage" do
      sign_in(member)
      post member_monitoring_clusters_path, params: { name: "lab", confirm: "1" }
      expect(organization.clusters.count).to eq(0)
    end
  end

  describe "GET show" do
    it "shows the four figures as a strip and the namespaces, with what is wrong in its own tab" do
      cluster = cluster_with_state
      sign_in(owner)

      get member_monitoring_cluster_path(cluster)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="cluster-strip"', 'data-test="cluster-strip-nodes"', 'data-test="cluster-strip-usage"')
      expect(response.body).to include('data-test="cluster-tab-problems"', 'data-test="cluster-tab-problems-count"')
      expect(response.body).not_to include('data-test="cluster-problems"', 'data-test="cluster-tiles"')
      expect(response.body).to include("shop")
    end

    it "lists what is wrong now as a table in the problems tab" do
      cluster = cluster_with_state
      sign_in(owner)

      get member_monitoring_cluster_problems_path(cluster)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="cluster-problems"', 'data-test="cluster-problem-workload_crashloop"',
                                       'data-test="cluster-problem-node_not_ready"', "CrashLoopBackOff", "shop")
      expect(response.body).to include("<table")
    end

    it "says all is good in the problems tab of a healthy cluster" do
      cluster = create(:cluster, organization:, name: "calm")
      create(:cluster_node, cluster:, name: "pool-a")
      sign_in(owner)

      get member_monitoring_cluster_problems_path(cluster)

      expect(response.body).to include('data-test="cluster-problems-none"')
    end

    it "answers 404 for a cluster of another organization" do
      foreign = create(:cluster)
      sign_in(owner)
      get member_monitoring_cluster_path(foreign)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "in Italian" do
    { "list" => ->(_c) { member_monitoring_clusters_path }, "new" => ->(_c) { new_member_monitoring_cluster_path },
      "overview" => ->(c) { member_monitoring_cluster_path(c) }, "machines" => ->(c) { member_monitoring_cluster_nodes_path(c) },
      "apps" => ->(c) { member_monitoring_cluster_workloads_path(c) },
      "problems" => ->(c) { member_monitoring_cluster_problems_path(c) } }.each do |page, path|
      it "renders the #{page} page without a missing translation" do
        cluster = cluster_with_state
        owner.update!(locale: "it")
        sign_in(owner)

        get instance_exec(cluster, &path)

        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include("translation missing", "Translation missing")
        expect(response.body).to include("lang=\"it\"", "Cluster")
      end
    end
  end

  describe "tabs" do
    it "lists the machines" do
      cluster = cluster_with_state
      sign_in(owner)
      get member_monitoring_cluster_nodes_path(cluster)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("pool-a", "pool-b", "25%")
    end

    it "lists the apps and filters them by namespace" do
      cluster = cluster_with_state
      other = create(:cluster_namespace, cluster:, name: "billing")
      create(:cluster_workload, cluster:, namespace: other, name: "invoices")
      sign_in(owner)

      get member_monitoring_cluster_workloads_path(cluster, namespace: [ "shop" ])

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("checkout", "shop/checkout:2.14.0")
      expect(response.body).not_to include("invoices")
    end
  end

  describe "managing a cluster" do
    it "pauses and resumes the alerts" do
      cluster = cluster_with_state
      sign_in(owner)
      patch member_monitoring_cluster_path(cluster, pause: "1", confirm: "1")
      expect(cluster.reload).to be_status_paused
      patch member_monitoring_cluster_path(cluster, pause: "0", confirm: "1")
      expect(cluster.reload).to be_status_pending
    end

    it "gives a new token and shows it once" do
      cluster = cluster_with_state
      old_digest = cluster.token_digest
      sign_in(owner)
      patch rotate_member_monitoring_cluster_path(cluster), params: { confirm: "1" }
      expect(response.body).to match(/cyi_k_[A-Za-z0-9]{40}/)
      expect(cluster.reload.token_digest).not_to eq(old_digest)
    end

    it "deletes only with the confirmation" do
      cluster = cluster_with_state
      sign_in(owner)
      delete member_monitoring_cluster_path(cluster)
      expect(Clusters::Cluster.exists?(cluster.id)).to be(true)
      delete member_monitoring_cluster_path(cluster), params: { confirm: "1" }
      expect(Clusters::Cluster.exists?(cluster.id)).to be(false)
    end
  end

  describe "linking a namespace" do
    it "links to a project environment and unlinks" do
      cluster = cluster_with_state
      namespace = cluster.namespaces.find_by!(name: "shop")
      project = create(:project, organization:)
      environment = create(:environment, organization:)
      Connections::ProjectEnvironment.create!(project:, environment:)
      sign_in(owner)

      patch member_monitoring_cluster_namespace_path(cluster, namespace), params: { link: "#{project.id}:#{environment.id}", confirm: "1" }
      expect(namespace.reload).to have_attributes(project_id: project.id, environment_id: environment.id)

      patch member_monitoring_cluster_namespace_path(cluster, namespace), params: { link: "", confirm: "1" }
      expect(namespace.reload.project_id).to be_nil
    end

    it "answers 404 for a project of another organization" do
      cluster = cluster_with_state
      namespace = cluster.namespaces.find_by!(name: "shop")
      sign_in(owner)
      patch member_monitoring_cluster_namespace_path(cluster, namespace), params: { link: "#{create(:project).id}:", confirm: "1" }
      expect(response).to have_http_status(:not_found)
      expect(namespace.reload.project_id).to be_nil
    end
  end
end
