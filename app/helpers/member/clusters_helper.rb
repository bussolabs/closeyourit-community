# frozen_string_literal: true

module Member
  # Status badges of the Kubernetes cluster pages (CYAG-22): one place decides label and color, so
  # the list, the cluster page and its tabs say the same thing (A5, A14).
  module ClustersHelper
    def cluster_status_badge(cluster, row, test_id: nil)
      label, color = cluster_status(cluster, row)
      render Ui::BadgeComponent.new(label:, color:, dot: true, test_id:)
    end

    def cluster_node_badge(node)
      label, color =
        if node.being_removed then [ t("member.clusters.nodes.removing"), :gray ]
        elsif !node.ready then [ t("member.clusters.nodes.not_ready", time: time_ago_in_words(node.not_ready_since || Time.current)), :red ]
        elsif node.pressured? then [ t("member.clusters.nodes.pressure"), :amber ]
        else [ t("member.clusters.nodes.ready"), :green ]
        end
      render Ui::BadgeComponent.new(label:, color:, dot: true)
    end

    def cluster_workload_badge(workload)
      label, color =
        if workload.crashlooping? then [ t("member.clusters.workloads.crashloop"), :red ]
        elsif workload.degraded? && workload.last_reason.present?
          [ t("member.clusters.workloads.waiting", reason: workload.last_reason), :amber ]
        elsif workload.degraded? then [ t("member.clusters.workloads.degraded", time: time_ago_in_words(workload.degraded_since || Time.current)), :amber ]
        else [ t("member.clusters.workloads.running"), :green ]
        end
      render Ui::BadgeComponent.new(label:, color:, dot: true)
    end

    # The share of a capacity, or nil when the cluster has no metrics-server.
    def cluster_usage_percent(used, capacity)
      return nil if used.nil? || capacity.to_i.zero?

      (used.to_f * 100 / capacity).round
    end

    private

    def cluster_status(cluster, row)
      if cluster.status_paused? then [ t("member.clusters.status.paused"), :gray ]
      elsif cluster.status_pending? then [ t("member.clusters.status.pending"), :sky ]
      elsif cluster.status_down? then [ t("member.clusters.status.down", time: time_ago_in_words(cluster.last_snapshot_at || cluster.created_at)), :red ]
      elsif row.attention.positive? then [ t("member.clusters.status.attention", count: row.attention), :amber ]
      else [ t("member.clusters.status.ok"), :green ]
      end
    end
  end
end
