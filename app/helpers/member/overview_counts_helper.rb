# frozen_string_literal: true

module Member
  # D16 — the counts on top of an area page link to the list they count, already filtered when the
  # count is about what is down. A count whose page the person cannot open stays plain text (F13).
  module OverviewCountsHelper
    OVERVIEW_COUNT_ROUTES = {
      "errors" => [ :member_monitoring_error_groups_path, { ft: 1, status: [ "unresolved" ] } ],
      "monitors" => [ :member_monitoring_monitors_path, {} ],
      "monitors_down" => [ :member_monitoring_monitors_path, { status: [ "down" ] } ],
      "servers" => [ :member_monitoring_servers_path, {} ],
      "servers_down" => [ :member_monitoring_servers_path, { status: [ "down" ] } ],
      "tickets_open" => [ :list_member_tickets_path, {} ],
      "ideas_open" => [ :member_ideas_path, {} ],
      "seo_issues_open" => [ :member_monitoring_seo_index_path, {} ],
      "seo_issues_critical" => [ :member_monitoring_seo_index_path, { severity: [ "critical" ] } ],
      "seo_sites" => [ :member_monitoring_seo_sites_path, {} ],
      "members" => [ :member_members_path, {} ],
      "service_accounts" => [ :member_service_accounts_path, {} ],
      "projects" => [ :member_projects_path, {} ]
    }.freeze

    def overview_count_href(key, visible_paths)
      route, filter = OVERVIEW_COUNT_ROUTES[key]
      return unless route && visible_paths.include?(public_send(route))

      public_send(route, filter)
    end
  end
end
