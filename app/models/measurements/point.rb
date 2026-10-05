# frozen_string_literal: true

module Measurements
  class Point < ApplicationRecord
    attribute :start_time_unix_nano, ActiveModel::Type::Decimal.new(precision: 20)
    attribute :time_unix_nano, ActiveModel::Type::Decimal.new(precision: 20)
    belongs_to :project, class_name: "Projects::Project"
    belongs_to :series, class_name: "Measurements::Series", inverse_of: :points
  end
end
