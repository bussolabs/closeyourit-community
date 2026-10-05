# frozen_string_literal: true

module Todos
  module Items
    # Crea o aggiorna una voce di una lista (title + link opzionale a un ticket). L'item arriva già
    # scoped alla lista posseduta dal controller (@list.items.build / .find). Il vincolo tenant sul
    # ticket (stessa org della lista) è nel model. Result pattern.
    class Save < ApplicationService
      def initialize(item:, attributes:)
        @item = item
        @attributes = attributes || {}
      end

      def call
        @item.assign_attributes(@attributes)
        return Result.ok(@item) if @item.save

        Result.err(AppError.new(I18n.t("todos.items.errors.invalid"),
                                code: "R422-TODOITEM-001", details: @item.errors.to_hash))
      end
    end
  end
end
