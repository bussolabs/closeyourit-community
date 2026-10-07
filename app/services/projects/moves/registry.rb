# frozen_string_literal: true

module Projects
  module Moves
    # Single source of truth of what a move does to each table. The guard in
    # spec/config/project_move_registry_spec.rb fails when a reachable table is missing here (CYRA-879).
    module Registry
      # Rows linked through <projects>/<groups> on <column> = <row>.id, all of them to moved subjects (CYRA-882).
      # COALESCE: an empty id list binds NULL, which would count a link to a staying subject as moved.
      LINKED_ONLY_TO_MOVED =
        "(EXISTS (SELECT 1 FROM %<projects>s l WHERE l.%<column>s = %<row>s.id AND l.project_id IN (:projects)) " \
        "OR EXISTS (SELECT 1 FROM %<groups>s l WHERE l.%<column>s = %<row>s.id AND l.group_id IN (:groups))) " \
        "AND NOT EXISTS (SELECT 1 FROM %<projects>s l WHERE l.%<column>s = %<row>s.id " \
        "AND NOT COALESCE(l.project_id IN (:projects), FALSE)) " \
        "AND NOT EXISTS (SELECT 1 FROM %<groups>s l WHERE l.%<column>s = %<row>s.id " \
        "AND NOT COALESCE(l.group_id IN (:groups), FALSE))"

      # A knowledge page of the source moves when every project and group link points to a moved subject.
      # Subject#page_ids evaluates it once; the rules below read the fixed list as :pages (CYRA-882).
      MOVING_PAGES = "knowledge_pages.organization_id = :organization AND " +
                     format(LINKED_ONLY_TO_MOVED, projects: "connections_page_projects", groups: "connections_page_groups",
                                                  column: "page_id", row: "knowledge_pages")

      # A book moves whole when it is linked only to moved subjects and all its pages are in :pages (CYRA-882).
      MOVING_BOOKS = "knowledge_books.organization_id = :organization AND " +
                     format(LINKED_ONLY_TO_MOVED, projects: "connections_book_projects", groups: "connections_book_groups",
                                                  column: "book_id", row: "knowledge_books") +
                     " AND NOT EXISTS (SELECT 1 FROM knowledge_pages bp WHERE bp.book_id = knowledge_books.id " \
                     "AND NOT COALESCE(bp.id IN (:pages), FALSE))"

      # Rows whose organization_id is rewritten to the destination (CYRA-879).
      FOLLOW = {
        "projects" => "id IN (:projects)",
        "projects_groups" => "id IN (:groups)",
        "agents_limit_policies" => "project_id IN (:projects)",
        "agents_attempts" => "workflow_id IN (SELECT id FROM agents_workflows WHERE ticket_id IN (:tickets))",
        "agents_supporter_decisions" => "workflow_id IN (SELECT id FROM agents_workflows WHERE ticket_id IN (:tickets))",
        "connections_account_secret_accesses" => "project_id IN (:projects)",
        "knowledge_sample_questions" => "project_id IN (:projects)",
        "knowledge_pages" => "id IN (:pages)",
        "knowledge_versions" => "page_id IN (:pages)",
        "knowledge_books" => "id IN (:books)",
        "product_categories" => "group_id IN (:groups)",
        "product_features" => "category_id IN (SELECT id FROM product_categories WHERE group_id IN (:groups))",
        "secrets_variables" => "project_id IN (:projects)",
        "secrets_overrides" => "project_id IN (:projects)",
        "secrets_events" => "project_id IN (:projects)",
        "secrets_change_requests" => "project_id IN (:projects)",
        "secrets_health_anomalies" => "project_id IN (:projects)",
        "secrets_assets" => "project_id IN (:projects)",
        "secrets_asset_events" => "project_id IN (:projects)",
        "secrets_shared_events" => "project_id IN (:projects)",
        "ticketing_events" => "ticket_id IN (:tickets)",
        "ticketing_subscriptions" => "ticket_id IN (:tickets)",
        "ticketing_work_context_snapshots" => "ticket_id IN (:tickets)"
      }.freeze

      # Polymorphic types a move carries, with the SQL listing their ids (CYRA-879).
      SUBJECT_IDS = {
        "Projects::Project" => ":projects",
        "Projects::Group" => ":groups",
        "Ticketing::Ticket" => ":tickets",
        "Projects::Document" => "SELECT id FROM projects_documents WHERE project_id IN (:projects)",
        "Projects::Milestone" => "SELECT id FROM projects_milestones WHERE project_id IN (:projects)",
        "Datasets::Dataset" => "SELECT id FROM datasets_datasets WHERE project_id IN (:projects)",
        "Ideas::Idea" => "SELECT id FROM ideas_ideas WHERE project_id IN (:projects)"
      }.freeze

      # Polymorphic tables: rows whose <prefix>_type/<prefix>_id point to one of SUBJECT_IDS follow (CYRA-879).
      POLYMORPHIC_FOLLOW = [
        %w[activity_events subject],
        %w[chat_conversations contextable],
        %w[guidance_procedures owner],
        %w[guidance_references owner]
      ].freeze

      # Links to rows the source organization keeps: removed, or the column set to NULL (CYRA-879).
      # The knowledge ones touch only what crosses organizations: see Detach.predicates (CYRA-882).
      DETACH = {
        "alerting_rules" => :delete,
        "alerting_notifications" => :delete,
        "agents_limit_reservations" => :delete,
        "agents_leases_tombstones" => :delete,
        "agents_ticket_queue_deferrals" => :delete,
        # Only the references that cross organizations; the rest follow their message in Execute#follow_chat! (CYRA-879).
        "chat_message_references" => :delete,
        "connections_book_projects" => :delete,
        "connections_book_groups" => :delete,
        "connections_page_projects" => :delete,
        "connections_page_groups" => :delete,
        "connections_page_links" => :delete,
        "connections_team_project_accesses" => :delete,
        "connections_team_group_accesses" => :delete,
        "connections_environment_hosts" => :delete,
        "agents_hosts" => { nullify: %w[heartbeat_project_id] },
        "uptime_monitors" => { nullify: %w[group_id] },
        "todos_items" => { nullify: %w[ticket_id] },
        "workload_actions" => { nullify: %w[ticket_id] },
        "knowledge_sample_questions" => { nullify: %w[knowledge_page_id] },
        "product_features" => { nullify: %w[knowledge_page_id] },
        "secrets_shared_events" => { nullify: %w[shared_variable_id] },
        # A cluster stays in the source organization: a moved project only loses its namespace link (CYAG-22).
        "clusters_namespaces" => { nullify: %w[project_id environment_id] },
        # A conversation belongs to its account in the source organization: it only loses the project it was fixed on.
        "assistant_conversations" => { nullify: %w[project_id] }
      }.freeze

      # Handled by dedicated code rather than generic rules (CYRA-879).
      SPECIAL = {
        "github_repositories" => "always detached: the app keeps no list of repositories an installation can see; " \
                                 "Github.apply! clears or deletes its agent rows first",
        "secrets_shared_delegations" => "remapped to the copied shared value (SharedSecrets)",
        "secrets_asset_delegations" => "remapped to the copied shared file (SharedSecrets)",
        "secrets_provisions" => "blocker when a side stays behind; otherwise follows",
        "agents_leases" => "blocker while an agent holds a ticket",
        "chat_messages" => "follow their moved conversation (Execute#follow_chat!)",
        "chat_participants" => "follow their moved conversation; non-members of the destination are deleted (Execute)",
        "coworkers_puckies" => "a team Puck bound to a moved project blocks the move (Plan#team_puckies)"
      }.freeze

      # Per-organization lookups rewritten by LookupMap (CYRA-879).
      LOOKUPS = {
        "ticketing_tickets" => { "status_id" => "types_ticket_statuses", "priority_id" => "types_ticket_priorities" },
        "connections_project_platforms" => { "platform_id" => "types_platforms" },
        "connections_ticket_platforms" => { "platform_id" => "types_platforms" },
        "connections_feature_platforms" => { "platform_id" => "types_platforms", "status_id" => "types_feature_statuses" },
        "connections_project_environments" => { "environment_id" => "types_environments" },
        "crons_monitors" => { "environment_id" => "types_environments" },
        "github_repositories" => { "preview_environment_id" => "types_environments",
                                   "production_environment_id" => "types_environments",
                                   "staging_environment_id" => "types_environments" },
        "projects_tokens" => { "environment_id" => "types_environments" },
        "secrets_variables" => { "environment_id" => "types_environments" },
        "secrets_overrides" => { "environment_id" => "types_environments" },
        "secrets_events" => { "environment_id" => "types_environments" },
        "secrets_change_requests" => { "environment_id" => "types_environments" },
        "secrets_health_anomalies" => { "environment_id" => "types_environments" },
        "secrets_assets" => { "environment_id" => "types_environments" },
        "secrets_asset_events" => { "environment_id" => "types_environments" },
        "secrets_shared_events" => { "environment_id" => "types_environments" },
        "secrets_provisions" => { "source_environment_id" => "types_environments",
                                  "destination_environment_id" => "types_environments" },
        "seo_sites" => { "environment_id" => "types_environments" },
        "uptime_monitors" => { "environment_id" => "types_environments" }
      }.freeze

      # Organization-scoped rows a move deliberately leaves where they are. The last three keep ids of
      # moved data that simply stop matching. agents_workflows moves with its ticket but keeps the
      # source agents in *_by_agent_id: it is not listed here, which would hide its other columns from
      # the guard (CYRA-879).
      IGNORED = {
        "agents_leases" => "a move is blocked while a lease exists",
        "alerting_rule_channels" => "deleted by cascade with their rule",
        "alerting_rule_host_exclusions" => "deleted with their rule in Execute",
        "assistant_messages" => "a message stays with its conversation in the source organization",
        "assistant_proposals" => "a proposal stays with the assistant reply that made it; a confirmed one keeps the id of what it created",
        "coworkers_device_calls" => "a computer request stays with its run and its computer in the source organization (CYRA-1029)",
        "coworkers_slack_links" => "a Slack link stays with its account; a move is blocked while a team Puck is bound (CYRA-1023)",
        "knowledge_ask_logs" => "past questions keep project_ids and group_ids as asked; history only",
        "saved_views" => "a saved filter on a moved project just finds nothing in the source",
        "secrets_consolidation_suggestions" => "realigned by the nightly Consolidation::ScanJob to the values the source still has"
      }.freeze

      # Links a move deliberately leaves alone: the row stays in the source organization (CYRA-879).
      KEPT_LINKS = {
        "workload_actions" => { "team_id" => "the action stays with its team in the source organization" },
        "todos_items" => { "list_id" => "the item stays in its personal list in the source organization" },
        "clusters_namespaces" => { "cluster_id" => "the namespace stays with its cluster in the source organization" },
        "clusters_workloads" => { "cluster_id" => "the workload stays with its cluster in the source organization" }
      }.freeze

      # Links rewritten by dedicated code rather than followed or detached (CYRA-882).
      REPOINTED = {
        "knowledge_pages" => { "book_id" => "a moved page whose book stays points to the destination book with the " \
                                            "same title, created when missing (KnowledgeBase)" }
      }.freeze

      # Links to a knowledge page that need no rewrite: the row goes wherever its page goes (CYRA-882).
      CARRIED_LINKS = {
        "knowledge_versions" => { "page_id" => "the version follows its page (FOLLOW)" },
        "knowledge_attachments" => { "page_id" => "no organization column: the attachment goes wherever its page goes" }
      }.freeze

      # No polymorphic column accepts a Knowledge type (activity, chat references, guidance, log links,
      # alert notifications): nothing else to follow. Embeddings and search data live on the page row (CYRA-882).

      module_function

      def classified_tables
        (FOLLOW.keys + DETACH.keys + SPECIAL.keys + IGNORED.keys + POLYMORPHIC_FOLLOW.map(&:first)).uniq
      end

      # A column is handled when its table is deleted/ignored/special as a whole, when it is
      # nullified, a kept link, a remapped lookup, or a followed organization_id (CYRA-879).
      def handles_column?(table, column)
        DETACH[table] == :delete || SPECIAL.key?(table) || IGNORED.key?(table) ||
          nullified?(table, column) || KEPT_LINKS.dig(table, column).present? || REPOINTED.dig(table, column).present? ||
          CARRIED_LINKS.dig(table, column).present? ||
          LOOKUPS.dig(table, column).present? ||
          (FOLLOW.key?(table) && column == "organization_id")
      end

      def nullified?(table, column)
        rule = DETACH[table]
        rule.is_a?(Hash) && rule[:nullify].include?(column)
      end
    end
  end
end
