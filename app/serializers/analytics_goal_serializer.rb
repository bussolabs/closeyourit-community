# frozen_string_literal: true

# Goal di conversione della dashboard analytics (canale CLI). kind = pageview_path / custom_event
# (enum string); path_pattern per i pageview, event_name per gli eventi custom.
class AnalyticsGoalSerializer < ApplicationSerializer
  attributes :id, :project_id, :kind, :display_name, :event_name, :path_pattern, :created_at
end
