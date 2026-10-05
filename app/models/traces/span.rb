# frozen_string_literal: true

module Traces
  class Span < ApplicationRecord
    # Rails infers scale-zero numeric as BigInteger; explicit decimal keeps uint64 quoting exact.
    attribute :start_time_unix_nano, ActiveModel::Type::Decimal.new(precision: 20)
    attribute :end_time_unix_nano, ActiveModel::Type::Decimal.new(precision: 20)

    belongs_to :project, class_name: "Projects::Project"
    belongs_to :trace_record, class_name: "Traces::Trace", inverse_of: :spans

    def resource_identity
      Monitoring::ResourceIdentity.call(resource: resource)
    end
  end
end
