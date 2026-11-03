# frozen_string_literal: true

# Goal di conversione della dashboard analytics (canale CLI). kind = pageview_path / custom_event
# (enum string); path_pattern per i pageview, event_name per gli eventi custom. property_name and
# property_value narrow an event goal to one property value (CYRA-1158).
class AnalyticsGoalSerializer < ApplicationSerializer
  attributes :id, :project_id, :kind, :display_name, :event_name, :path_pattern, :property_name, :property_value, :created_at
end
