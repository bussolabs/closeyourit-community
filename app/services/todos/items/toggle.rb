# frozen_string_literal: true

module Todos
  module Items
    # Inverte lo stato fatto/non-fatto di una voce (o lo imposta esplicito con done:), tenendo
    # coerente completed_at. Usato dalla spunta inline web e dall'endpoint completion CLI.
    class Toggle < ApplicationService
      def initialize(item:, done: nil)
        @item = item
        @done = done
      end

      def call
        @done.nil? ? @item.mark(done: !@item.done?) : @item.mark(done: @done)
        return Result.ok(@item) if @item.save

        Result.err(AppError.new(I18n.t("todos.items.errors.invalid"),
                                code: "R422-TODOITEM-001", details: @item.errors.to_hash))
      end
    end
  end
end
