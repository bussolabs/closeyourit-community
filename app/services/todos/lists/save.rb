# frozen_string_literal: true

module Todos
  module Lists
    # Crea o aggiorna una lista di todo (name/color). La lista arriva già scoped al proprietario e
    # all'org dal controller (Current.account.todo_lists.build / .find). Result pattern.
    class Save < ApplicationService
      def initialize(list:, attributes:)
        @list = list
        @attributes = attributes || {}
      end

      def call
        @list.assign_attributes(@attributes)
        return Result.ok(@list) if @list.save

        Result.err(AppError.new(I18n.t("todos.lists.errors.invalid"),
                                code: "R422-TODOLIST-001", details: @list.errors.to_hash))
      end
    end
  end
end
