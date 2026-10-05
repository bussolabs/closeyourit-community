# frozen_string_literal: true

module Member
  module TodoLists
    # Condivisione in sola lettura di una lista posseduta con membri scelti dell'org. set_list scoped
    # all'ownership (altrui/condivisa-con-me → 404: solo il proprietario gestisce i destinatari).
    class SharingsController < Member::BaseController
      permission_not_required "Destinatari di una lista propria: soltanto il proprietario li sceglie."

      before_action :set_list

      # CYRA-556 — fra i destinatari comparivano anche le utenze che usano i programmi, che dal sito
      # non entrano mai: una lista condivisa con loro non la leggerebbe nessuno, e intanto allungava
      # l'elenco da scorrere. Solo persone. Il rifiuto vero sta su Todos::Share (vale per ogni canale).
      def show
        @members = Current.organization.accounts.human.where.not(id: Current.account.id).order(:name)
        @selected = @list.shares.pluck(:account_id)
      end

      def update
        result = Todos::Shares::SetShares.call(list: @list, account_ids: params[:account_ids])
        if result.ok?
          redirect_to member_todo_list_path(@list), notice: t("member.todo_lists.share.updated")
        else
          redirect_to member_todo_list_sharing_path(@list), alert: result.error.message
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
