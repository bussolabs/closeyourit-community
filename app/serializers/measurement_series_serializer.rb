# frozen_string_literal: true

class MeasurementSeriesSerializer < ApplicationSerializer
  attributes :id, :identity_digest, :name, :unit, :description, :metric_type, :temporality, :monotonic,
             :resource, :instrumentation_scope, :point_attributes, :resource_schema_url, :scope_schema_url,
             :first_received_at, :last_admitted_at, :resource_identity
  attribute(:api_schema_version) { 1 }
end
