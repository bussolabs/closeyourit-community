# frozen_string_literal: true

module Notifications
  # Where a notification leads, composed from its subject when it is read instead of frozen when it
  # was written: renaming a page moves every old notification with it. nil when the subject is gone
  # or has no page of its own; Alerting::Notification#url then falls back to the stored path.
  module Link
    # Subjects whose page depends only on the record itself.
    BY_SUBJECT = {
      "Errors::Group" => ->(r, s) { r.member_monitoring_error_group_path(s) },
      "Uptime::Incident" => ->(r, s) { r.member_monitoring_monitor_path(s.monitor_id) },
      "Uptime::Monitor" => ->(r, s) { r.member_monitoring_monitor_path(s) },
      "Crons::Monitor" => ->(r, _s) { r.member_monitoring_cron_monitors_path },
      "Metrics::Group" => ->(r, s) { r.member_monitoring_metric_group_path(s) },
      "Alerting::Evaluation" => ->(r, s) { r.member_project_path(s.project_id) },
      "Logs::Entry" => ->(r, s) { r.member_monitoring_log_entry_path(s) },
      "Servers::Host" => ->(r, s) { r.member_monitoring_server_path(s) },
      "Clusters::Cluster" => ->(r, s) { r.member_monitoring_cluster_path(s) },
      "Clusters::Node" => ->(r, s) { r.member_monitoring_cluster_path(s.cluster_id) },
      "Clusters::Workload" => ->(r, s) { r.member_monitoring_cluster_path(s.cluster_id) },
      "Agents::Host" => ->(r, s) { r.member_agent_path(s) },
      "Vulnerabilities::Finding" => ->(r, s) { r.member_monitoring_vulnerability_path(s) },
      "Vulnerabilities::RuntimeStatus" => ->(r, _s) { r.runtimes_member_monitoring_vulnerabilities_path },
      "Seo::Issue" => ->(r, s) { r.member_monitoring_seo_path(s) },
      "Secrets::Event" => ->(r, s) { r.member_project_secret_events_path(s.project_id) },
      "Ideas::Idea" => ->(r, s) { r.member_idea_path(s) },
      "Ideas::Comment" => ->(r, s) { r.member_idea_path(s.idea_id) },
      "Workload::Action" => ->(r, s) { r.member_workload_action_path(s) },
      "Datasets::Training" => ->(r, s) { r.member_dataset_training_path(s.dataset_id, s) },
      "Ticketing::Ticket" => ->(r, s) { r.member_ticket_path(s) },
      "Chat::Message" => ->(r, s) { r.member_chat_conversation_path(s.conversation_id) },
      "Secrets::Variable" => ->(r, _s) { r.member_vault_attention_path },
      "Secrets::Consolidation::Suggestion" => ->(r, s) { r.member_vault_consolidation_path(s) },
      "Projects::Token" => ->(r, s) { r.member_project_tokens_path(s.project_id) }
    }.freeze

    # A project or an organization stands for many events: the event picks the page.
    BY_EVENT = {
      "analytics_traffic_drop" => ->(r, s) { r.member_monitoring_analytics_path(project_id: s.id) },
      "analytics_traffic_spike" => ->(r, s) { r.member_monitoring_analytics_path(project_id: s.id) },
      "secret_deleted" => ->(r, s) { r.member_project_secrets_path(s) },
      "secret_change_approved" => ->(r, s) { r.member_project_secrets_path(s) },
      "secret_change_rejected" => ->(r, s) { r.member_project_secrets_path(s) },
      "secret_change_requested" => ->(r, _s) { r.member_vault_attention_path },
      "secret_sync_failed" => ->(r, s) { r.member_project_github_path(s) },
      "server_ingest_rejected" => ->(r, _s) { r.member_monitoring_servers_path },
      "cache_unavailable" => ->(r, _s) { r.member_monitoring_servers_path },
      "embedding_down" => ->(r, _s) { r.member_agents_path },
      "agents_stalled" => ->(r, _s) { r.member_agents_path },
      "ai_unavailable" => ->(r, _s) { r.member_integrations_path },
      "ai_available" => ->(r, _s) { r.member_integrations_path }
    }.freeze

    def self.for(notification)
      subject = notification.subject
      return nil if subject.nil?

      builder = BY_EVENT[notification.event_type.to_s] || BY_SUBJECT[subject.class.name]
      builder&.call(Rails.application.routes.url_helpers, subject)
    end
  end
end
