# frozen_string_literal: true

module Alerting
  module Measurements
    class DispatchJob < ApplicationJob
      queue_as :alerts

      def perform(evaluation_id:)
        Dispatch.call(evaluation_id: evaluation_id)
      end
    end
  end
end
