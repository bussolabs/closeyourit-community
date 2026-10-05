# frozen_string_literal: true

module Alerting
  class Evaluation < ApplicationRecord
    self.table_name = "alerting_evaluations"
    attribute :window_end_ns, ActiveModel::Type::Decimal.new(precision: 20)
    belongs_to :rule, class_name: "Alerting::Rule"
    belongs_to :project, class_name: "Projects::Project"
  end
end
