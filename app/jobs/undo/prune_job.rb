# frozen_string_literal: true

module Undo
  # CYRA-1150 — an undo lives a few seconds: the expired entries go, nobody can use them any more.
  class PruneJob < ApplicationJob
    queue_as :batch

    def perform
      ::Undo::Entry.expired.in_batches(&:delete_all)
    end
  end
end
