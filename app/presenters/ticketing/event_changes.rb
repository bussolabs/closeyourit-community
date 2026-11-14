# frozen_string_literal: true

module Ticketing
  # The before/after texts of an `updated` event, one per field, whatever shape `data` stored them in:
  # [before, after] columns, from/to labels, or platforms added/removed. CYRA-1309
  class EventChanges
    Change = Data.define(:field, :before, :after)

    def self.call(event) = new(event).call

    def initialize(event)
      @event = event
    end

    def call
      return [] unless @event.action == "updated"

      @event.data.to_h
            .filter_map { |field, value| change(field, value) }
            .sort_by { |change| [ ActivityPresenter::FIELD_ORDER.index(change.field) || ActivityPresenter::FIELD_ORDER.size, change.field ] }
    end

    private

    def change(field, value)
      if value.is_a?(Array) && value.size == 2
        Change.new(field, value.first.to_s, value.last.to_s)
      elsif value.is_a?(Hash) && value.key?("from")
        Change.new(field, value["from"].to_s, value["to"].to_s)
      elsif value.is_a?(Hash) && value.key?("added")
        Change.new(field, Array(value["removed"]).join("\n"), Array(value["added"]).join("\n"))
      end
    end
  end
end
