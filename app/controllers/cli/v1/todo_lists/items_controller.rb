# frozen_string_literal: true

module Cli
  module V1
    module TodoLists
      # Voci di una lista posseduta via CLI. La lista è risolta nello scope di ownership (lista
      # altrui → R404); la voce è cercata dentro la lista (anti cross-lista → R404).
      class ItemsController < Cli::V1::BaseController
        before_action :set_list
        before_action :set_item, only: %i[update destroy]

        def index
          records, meta = paginate(@list.items.ordered.includes(ticket: :project))
          render_ok(TodoItemSerializer.new(records), meta: meta)
        end

        def create
          render_result(Todos::Items::Save.call(item: @list.items.build, attributes: item_params), created: true)
        end

        def update
          render_result(Todos::Items::Save.call(item: @item, attributes: item_params))
        end

        def destroy
          @item.destroy
          render_no_content
        end

        private

        def set_list
          @list = Todos::List.for(account: Current.account, organization: Current.organization)
                             .find(params[:todo_list_id])
        end

        def set_item
          @item = @list.items.find(params[:id])
        end

        def item_params
          params.permit(:title, :ticket_id, :position)
        end

        def render_result(result, created: false)
          if result.ok?
            created ? render_created(TodoItemSerializer.new(result.value)) : render_ok(TodoItemSerializer.new(result.value))
          else
            render_error(result.error.code, result.error.message,
                         status: result.error.status, details: result.error.details)
          end
        end
      end
    end
  end
end
