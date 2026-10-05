# frozen_string_literal: true

module SessionHealth
  class Aggregate < ApplicationRecord
    belongs_to :project, class_name: "Projects::Project", inverse_of: :health_aggregates
    %i[exited errored unhandled crashed abnormal].each do |name|
      attribute name, ActiveModel::Type::Decimal.new(precision: 20)
    end
  end
end
