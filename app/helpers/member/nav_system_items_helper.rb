# frozen_string_literal: true

module Member
  # The SYSTEM section: whether the system is up (errors, performance, logs), what it runs on
  # (machines, uptime), who hears about it (alerts), who works for us (agents) and whether the site
  # can be found. SEO sits here, not inside observability: it answers another question (CYRA-742).
  module NavSystemItemsHelper
    private

    # Technical health of the system.
    def observability_items
      cp = controller.controller_path

      [
        { label: "member.nav.overview", path: member_observability_path, icon: "compass",
          test: "member-nav-observability-overview", visible: true, overview: true, active: overview_active?("observability") },
        { label: "member.nav.errors", path: member_monitoring_error_groups_path, icon: "bug",
          test: "member-nav-errors", visible: errors_nav_visible?, active: cp == "member/monitoring/error_groups" },
        { label: "member.nav.performance", path: member_monitoring_metric_groups_path, icon: "gauge",
          test: "member-nav-performance", visible: performance_nav_visible?,
          active: cp == "member/monitoring/metric_groups" },
        { label: "member.nav.logs", path: member_monitoring_log_entries_path, icon: "list",
          test: "member-nav-logs", visible: logs_nav_visible?, active: cp == "member/monitoring/log_entries" },
        { label: "member.nav.traces", path: member_monitoring_traces_path, icon: "git-branch",
          test: "member-nav-traces", visible: traces_nav_visible?, active: cp == "member/monitoring/traces" },
        { label: "member.nav.measurements", path: member_monitoring_measurements_path, icon: "chart-no-axes-combined",
          test: "member-nav-measurements", visible: measurements_nav_visible?,
          active: cp.in?(%w[member/monitoring/measurements member/monitoring/measurement_rules]) },
        { label: "member.nav.session_health", path: member_monitoring_session_health_path, icon: "heart-pulse",
          test: "member-nav-session-health", visible: session_health_nav_visible?,
          active: cp == "member/monitoring/session_health" },
        # Listed even where nothing records yet: the empty page teaches how to turn it on (CYRA-376).
        { label: "member.nav.replays", path: member_monitoring_replays_path, icon: "film",
          test: "member-nav-replays", visible: replays_nav_visible?,
          active: cp == "member/monitoring/replays" },
        { label: "member.nav.vulnerabilities", path: member_monitoring_vulnerabilities_path,
          icon: "shield-half", test: "member-nav-vulnerabilities", visible: vulnerabilities_nav_visible?,
          active: cp == "member/monitoring/vulnerabilities" }
      ]
    end

    # Machines and uptime signals.
    def infrastructure_items
      cp = controller.controller_path

      [
        { label: "member.nav.overview", path: member_infrastructure_path, icon: "compass",
          test: "member-nav-infrastructure-overview", visible: true, overview: true, active: overview_active?("infrastructure") },
        { label: "member.nav.uptime", path: member_monitoring_monitors_path, icon: "heart-pulse",
          test: "member-nav-uptime", visible: uptime_nav_visible?,
          active: cp.in?(%w[member/monitoring/monitors member/monitoring/incidents member/monitoring/uptime_groups]) },
        { label: "member.nav.status_page", path: member_monitoring_status_page_path, icon: "globe",
          test: "member-nav-status-page", visible: uptime_nav_visible?,
          active: cp == "member/monitoring/status_pages" },
        { label: "member.nav.crons", path: member_monitoring_cron_monitors_path,
          icon: "history", test: "member-nav-crons", visible: crons_nav_visible?,
          active: cp == "member/monitoring/cron_monitors" },
        { label: "member.nav.servers", path: member_monitoring_servers_path, icon: "server",
          test: "member-nav-servers", visible: servers_nav_visible?,
          active: cp.in?(%w[member/monitoring/servers member/monitoring/server_tokens member/monitoring/server_databases]) },
        { label: "member.nav.clusters", path: member_monitoring_clusters_path, icon: "container",
          test: "member-nav-clusters", visible: servers_nav_visible?,
          active: cp.in?(%w[member/monitoring/clusters member/monitoring/cluster_nodes
                            member/monitoring/cluster_workloads member/monitoring/cluster_namespaces]) },
        { label: "member.nav.databases", path: member_monitoring_databases_path, icon: "database",
          test: "member-nav-databases", visible: servers_nav_visible?,
          active: cp == "member/monitoring/databases" }
      ]
    end

    # The alert chain in order: the rule decides, the notification arrives, the channel carries it out
    # (CYRA-486, CYRA-496). Its own group since CYRA-903: it was the tail of a nine-entry Infrastructure.
    def alerts_items
      cp = controller.controller_path

      [
        { label: "member.nav.overview", path: member_alerts_path, icon: "compass",
          test: "member-nav-alerts-overview", visible: true, overview: true, active: overview_active?("alerts") },
        { label: "member.nav.alert_rules", path: member_alerting_rules_path, icon: "bell",
          test: "member-nav-alerts", visible: can?("alerts.manage"), active: cp == "member/alerting_rules" },
        # Personal: visible to any account, not behind the rules' permission.
        { label: "member.nav.alerts", path: member_alerting_notifications_path, icon: "inbox",
          test: "member-nav-alert-notifications", visible: alert_notifications_nav_visible?,
          active: cp == "member/alerting_notifications" },
        # Behind the rules' permission, which is the one that opens the page.
        { label: "member.nav.alert_channels", path: member_alerting_channels_path, icon: "send",
          test: "member-nav-alert-channels", visible: can?("alerts.manage"),
          active: cp == "member/alerting_channels" }
      ]
    end

    def automation_items
      cp = controller.controller_path

      [
        { label: "member.nav.overview", path: member_automation_path, icon: "compass",
          test: "member-nav-automation-overview", visible: true, overview: true, active: overview_active?("automation") },
        { label: "member.nav.datasets", path: member_datasets_path, icon: "wand-sparkles",
          test: "member-nav-datasets", visible: datasets_nav_visible?,
          active: cp.start_with?("member/datasets") },
        # Skill bundle versions are an admin form, not a menu entry: reached from the agents page (CYRA-453).
        { label: "member.nav.agents", path: member_agents_path, icon: "bot",
          test: "member-nav-agents", visible: agents_nav_visible?,
          active: cp.start_with?("member/agents") || cp.start_with?("member/skill_bundles") }
      ]
    end

    # Whether the site can be found, and who reaches it (CYRA-535). `active` checks controller AND
    # action: the three SEO pages share one controller and would all light up together.
    def seo_items
      cp = controller.controller_path
      on_seo = cp == "member/monitoring/seo"
      on_pages = on_seo && controller.action_name == "pages"

      [
        { label: "member.nav.overview", path: member_seo_path, icon: "compass",
          test: "member-nav-seo-overview", visible: true, overview: true,
          active: overview_active?("seo") },
        { label: "member.nav.seo_sites", path: member_monitoring_seo_sites_path, icon: "globe",
          test: "member-nav-seo-sites", visible: seo_nav_visible?,
          active: cp == "member/monitoring/seo_sites" },
        { label: "member.nav.seo_issues", path: member_monitoring_seo_index_path,
          icon: "triangle-alert", test: "member-nav-seo-issues", visible: seo_nav_visible?,
          active: on_seo && !on_pages },
        { label: "member.nav.seo_pages", path: pages_member_monitoring_seo_index_path,
          icon: "file-text", test: "member-nav-seo-pages", visible: seo_nav_visible?,
          active: on_pages },
        { label: "member.nav.analytics", path: member_monitoring_analytics_path, icon: "chart-line",
          test: "member-nav-analytics", visible: analytics_nav_visible?,
          active: cp.start_with?("member/monitoring/analytics") }
      ]
    end
  end
end
