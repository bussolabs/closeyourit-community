# frozen_string_literal: true

module Member
  module Monitoring
    # Kubernetes clusters watched by closeyourit-kube (CYAG-22): list, add with a token shown once,
    # cluster page, pause, new token, delete. Read with servers.view, write with servers.manage.
    class ClustersController < Member::BaseController
      include Indexable

      SORT_COLUMNS = {
        "name" => "LOWER(clusters_clusters.name)",
        "status" => :status,
        "last_snapshot" => :last_snapshot_at
      }.freeze

      before_action :require_view
      before_action :require_manage, only: %i[new create update destroy rotate]
      before_action :set_cluster, only: %i[show update destroy rotate]

      remembers_filters :q, :sort, only: :index

      def index
        scope = filter_by_search(visible.clusters.order(:name), "clusters_clusters.name")
        @clusters = paginated(scope, columns: SORT_COLUMNS)
        @summary = Member::ClusterSummary.new(@clusters)
        load_counts
      end

      def new
        @cluster = visible.clusters.new(color: "teal")
      end

      def create
        result = ::Clusters::Tokens::Issue.call(organization: Current.organization, name: params[:name],
                                                color: params[:color].presence, created_by: Current.account)
        if result.ok?
          show_with_secret(result.value[:cluster], result.value[:secret], status: :created)
        else
          @cluster = visible.clusters.new(name: params[:name], color: params[:color])
          @errors = result.error.details || { base: [ result.error.message ] }
          render :new, status: :unprocessable_content
        end
      end

      def show
        load_overview
      end

      # Name, color and pause. Resuming puts the cluster back to pending: the next snapshot or the
      # stale check says what it really is.
      def update
        attributes = params.permit(:name, :color).to_h.compact_blank
        attributes[:status] = :paused if params[:pause] == "1"
        attributes[:status] = :pending if params[:pause] == "0" && @cluster.status_paused?
        if @cluster.update(attributes)
          redirect_to member_monitoring_cluster_path(@cluster), notice: t("member.clusters.updated")
        else
          redirect_to member_monitoring_cluster_path(@cluster), alert: @cluster.errors.full_messages.to_sentence
        end
      end

      def rotate
        result = ::Clusters::Tokens::Rotate.call(cluster: @cluster)
        show_with_secret(@cluster, result.value[:secret], status: :ok)
      end

      # The confirmation the dialog sends is required by DangerousActionConfirmation (CYRA-728).
      def destroy
        @cluster.destroy!
        redirect_to member_monitoring_clusters_path, notice: t("member.clusters.deleted", name: @cluster.name)
      end

      private

      # The secret is rendered once, here: never in the session, the flash or the database.
      def show_with_secret(cluster, secret, status:)
        @cluster = cluster
        @revealed_secret = secret
        load_overview
        render :show, status:
      end

      def load_overview
        @problems = ::Clusters::Health.problems(@cluster)
        @summary = Member::ClusterSummary.new([ @cluster ]).for(@cluster)
        @namespaces = @cluster.namespaces.present.includes(:project, :environment).order(:name)
        @restarts_24h = @cluster.workloads.present.sum { |workload| workload.restarts_24h }
        @usage = node_usage
        @link_options = link_options if can?("servers.manage")
      end

      # One option per project and per environment it declares, plus "no project": value project_id:environment_id.
      def link_options
        projects = visible.projects.includes(:environments).order(:name)
        [ [ t("member.clusters.namespaces.none_project"), "" ] ] + projects.flat_map do |project|
          [ [ project.name, "#{project.id}:" ] ] +
            project.environments.map { |environment| [ "#{project.name} · #{environment.label}", "#{project.id}:#{environment.id}" ] }
        end
      end

      def node_usage
        nodes = @cluster.nodes.present.where.not(cpu_usage_millicores: nil)
        return nil if nodes.empty?

        { cpu: percent(nodes.sum(:cpu_usage_millicores), nodes.sum(:cpu_capacity_millicores)),
          memory: percent(nodes.sum(:memory_usage_bytes), nodes.sum(:memory_capacity_bytes)) }
      end

      def percent(used, total) = total.to_i.positive? ? (used.to_f * 100 / total).round : nil

      def load_counts
        all = visible.clusters
        @total_count = all.count
        @down_count = all.status_down.count
        up = all.status_up.to_a
        summary = Member::ClusterSummary.new(up)
        @attention_count = up.count { |cluster| summary.for(cluster).attention.positive? }
      end

      def set_cluster
        @cluster = visible.clusters.find(params[:id])
      end

      def require_view = require_permission!("servers.view")

      def require_manage = require_permission!("servers.manage")
    end
  end
end
