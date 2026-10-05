# frozen_string_literal: true

module Cli
  module V1
    # Liste RICEVUTE (condivise con me in sola lettura) via CLI. Scope = liste di cui sono
    # destinatario nell'org corrente; il find dentro lo scope è anti-BOLA (una lista non condivisa
    # con me → RecordNotFound → R404). Nessuna mutazione: index/show soltanto.
    class SharedTodoListsController < Cli::V1::BaseController
      def index
        records, meta = paginate(shared_lists.ordered.includes(:account, :items))
        render_ok(TodoListSerializer.new(records), meta: meta)
      end

      def show
        render_ok(TodoListSerializer.new(shared_lists.find(params[:id])))
      end

      private

      def shared_lists
        Todos::List.shared_with(Current.account).where(organization_id: Current.organization.id)
      end
    end
  end
end
