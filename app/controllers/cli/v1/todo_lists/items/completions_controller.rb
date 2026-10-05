# frozen_string_literal: true

module Cli
  module V1
    module TodoLists
      module Items
        # Completamento di una voce come sub-resource singleton: PUT = fatto, DELETE = riapri. La
        # lista è risolta nello scope di ownership (altrui → R404), la voce dentro la lista.
        class CompletionsController < Cli::V1::BaseController
          before_action :set_item

          def update
            render_toggle(Todos::Items::Toggle.call(item: @item, done: true))
          end

          def destroy
            render_toggle(Todos::Items::Toggle.call(item: @item, done: false))
          end

          private

          def set_item
            list = Todos::List.for(account: Current.account, organization: Current.organization)
                              .find(params[:todo_list_id])
            @item = list.items.find(params[:item_id])
          end

          def render_toggle(result)
            if result.ok?
              render_ok(TodoItemSerializer.new(result.value))
            else
              render_error(result.error.code, result.error.message,
                           status: result.error.status, details: result.error.details)
            end
          end
        end
      end
    end
  end
end
