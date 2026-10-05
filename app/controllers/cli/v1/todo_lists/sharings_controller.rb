# frozen_string_literal: true

module Cli
  module V1
    module TodoLists
      # Destinatari (sola lettura) di una lista posseduta via CLI. show = elenco membri con cui è
      # condivisa; update = imposta l'insieme (diff add/remove, tenant-integrity nel service).
      class SharingsController < Cli::V1::BaseController
        before_action :set_list

        def show
          render_ok(TodoShareSerializer.new(@list.shared_accounts))
        end

        def update
          result = Todos::Shares::SetShares.call(list: @list, account_ids: params[:account_ids])
          if result.ok?
            render_ok(TodoShareSerializer.new(@list.shared_accounts.reload))
          else
            render_error(result.error.code, result.error.message,
                         status: result.error.status, details: result.error.details)
          end
        end

        private

        def set_list
          @list = Todos::List.for(account: Current.account, organization: Current.organization)
                             .find(params[:todo_list_id])
        end
      end
    end
  end
end
