# frozen_string_literal: true

# A declared analytics event with its expected property names (CLI channel, CYRA-1158).
class AnalyticsEventDefinitionSerializer < ApplicationSerializer
  attributes :id, :project_id, :name, :property_names, :created_at, :updated_at
end
