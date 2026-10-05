# frozen_string_literal: true

module Measurements
  class Series < ApplicationRecord
    self.table_name = "measurements_series"
    belongs_to :project, class_name: "Projects::Project"
    has_many :points, class_name: "Measurements::Point", foreign_key: :series_id, dependent: :delete_all, inverse_of: :series

    def resource_identity = Monitoring::ResourceIdentity.call(resource: resource)
  end
end
