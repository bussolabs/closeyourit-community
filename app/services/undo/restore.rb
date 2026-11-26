# frozen_string_literal: true

module Undo
  # CYRA-1150 — puts back what a bulk action changed. Only the rows still exactly as the action left them
  # go back: one a colleague or a returning error changed since stays as it is. `ids` are the rows the
  # actor may still change; the entry is spent, so a second click finds nothing.
  class Restore < ApplicationService
    Outcome = Data.define(:restored_ids, :kept)

    def initialize(entry:, ids:)
      @entry = entry
      @ids = Array(ids)
    end

    def call
      Entry.transaction do
        @entry.lock!
        back = restorable_items
        back.group_by { |item| item["before"] }.each do |before, items|
          @entry.model.where(id: items.pluck("id"))
                .update_all(before.merge("updated_at" => Time.current)) # rubocop:disable Rails/SkipsModelValidations
        end
        @entry.destroy!
        Result.ok(Outcome.new(restored_ids: back.pluck("id"), kept: @entry.items.size - back.size))
      end
    end

    private

    # Compared on the written columns, not on updated_at: every new occurrence of an error touches that.
    def restorable_items
      rows = @entry.model.where(id: @entry.item_ids & @ids).order(:id).lock.index_by(&:id)
      @entry.items.select do |item|
        row = rows[item["id"]]
        row && Entry.snapshot(row, @entry.kind) == item["after"]
      end
    end
  end
end
