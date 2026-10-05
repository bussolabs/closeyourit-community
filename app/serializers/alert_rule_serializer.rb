# frozen_string_literal: true

class AlertRuleSerializer < ApplicationSerializer
  attributes :id, :name, :event_type, :min_level, :threshold_ms, :threshold, :throttle_seconds,
             :enabled, :project_id, :environment_id, :created_at,
             :measurement_series_id, :measurement_config, :measurement_state
end
