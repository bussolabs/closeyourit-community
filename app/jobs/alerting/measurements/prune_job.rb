# frozen_string_literal: true

module Alerting
  module Measurements
    class PruneJob < ApplicationJob
      queue_as :batch
      BATCH_SIZE = 1_000

      def perform
        ids = Evaluation.where(created_at: ...30.days.ago).order(:id).limit(BATCH_SIZE).pluck(:id)
        Evaluation.where(id: ids).delete_all
        self.class.perform_later if ids.size == BATCH_SIZE
      end
    end
  end
end
