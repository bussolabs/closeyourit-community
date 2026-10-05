# frozen_string_literal: true

class MonitorSerializer < ApplicationSerializer
  attributes :id, :project_id, :environment_id, :name, :check_type, :url, :host, :port, :http_method,
             :interval_seconds, :expected_status, :timeout_seconds, :latency_threshold_ms,
             :failure_threshold, :active, :public_status_enabled, :current_status, :last_checked_at,
             :created_at
end
