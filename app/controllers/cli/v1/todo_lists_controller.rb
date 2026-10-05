# frozen_string_literal: true

module Cli
  module V1
    # Liste di todo personali via CLI. Dati POSSEDUTI dall'utente → nessuna permission key: lo scope
    # è l'ownership (Current.account.todo_lists nell'org corrente), il find dentro quello scope è
    # anti-BOLA (lista altrui → RecordNotFound → R404). Le liste ricevute stanno in SharedTodoLists.
    class TodoListsController < Cli::V1::BaseController
      before_action :set_list, only: %i[show update destroy]

      def index
        records, meta = paginate(owned_lists.ordered.includes(:account, :items))
        render_ok(TodoListSerializer.new(records), meta: meta)
      end

      def show
        render_ok(TodoListSerializer.new(@list))
      end

      def create
        render_result(Todos::Lists::Save.call(list: owned_lists.build, attributes: list_params), created: true)
      end

      def update
        render_result(Todos::Lists::Save.call(list: @list, attributes: list_params))
      end

      def destroy
        @list.destroy
        render_no_content
      end

      # Riordina le liste possedute (collection): ordered_ids = ids nell'ordine desiderato. Ownership,
      # nessuna permission key. Specchio di Member::TodoListsController#reorder.
      def reorder
        result = Todos::Lists::Reorder.call(account: Current.account, organization: Current.organization,
                                            ordered_ids: params[:ordered_ids])
        if result.ok?
          render_no_content
        else
          render_error(result.error.code, result.error.message, status: result.error.status)
        end
      end

      private

      def owned_lists
        Todos::List.for(account: Current.account, organization: Current.organization)
      end

      def set_list
        @list = owned_lists.find(params[:id])
      end

      def list_params
        params.permit(:name, :color)
      end

      def render_result(result, created: false)
        if result.ok?
          created ? render_created(TodoListSerializer.new(result.value)) : render_ok(TodoListSerializer.new(result.value))
        else
          render_error(result.error.code, result.error.message,
                       status: result.error.status, details: result.error.details)
        end
      end
    end
  end
end
