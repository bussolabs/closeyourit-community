# frozen_string_literal: true

module Monitoring
  class ResourceIdentity < ApplicationService
    def initialize(resource:)
      @resource = resource
    end

    def call
      attributes = @resource.fetch("attributes", []).to_h { |item| [ item["key"], item.fetch("value", {})["stringValue"] ] }
      canonical = attributes["deployment.environment.name"]
      legacy = attributes["deployment.environment"]
      { service_name: attributes["service.name"].presence, service_namespace: attributes["service.namespace"].presence,
        service_version: attributes["service.version"].presence, service_instance_id: attributes["service.instance.id"].presence,
        environment: (attributes.key?("deployment.environment.name") ? canonical : legacy).presence,
        environment_conflict: attributes.key?("deployment.environment.name") && attributes.key?("deployment.environment") && canonical != legacy }
    end
  end
end
