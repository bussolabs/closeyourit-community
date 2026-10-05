# frozen_string_literal: true

module Projects
  module Moves
    # Runs a requested move; a retried job never runs a finished move twice (CYRA-879).
    class ExecuteJob < ApplicationJob
      queue_as :batch

      def perform(move_id)
        Projects::Move.expire_stale!
        move = Projects::Move.find_by(id: move_id)
        return unless move&.pending?

        Execute.call(move:)
      end
    end
  end
end
